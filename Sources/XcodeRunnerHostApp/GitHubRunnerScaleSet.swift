import Foundation
import Observation
import XcodeRunnerKit
import XcodeRunnerHostSupport

package enum GitHubRunnerAccess: String, Codable, Sendable {
    case connect
    case checkConnection
    case acceptJob
}

/// One repository runner's GitHub scale set. An offer remains on GitHub until the host acquires it.
package struct GitHubRunnerScaleSet: Sendable {
    package struct Grant: Codable, Sendable {
        let repository: String
        let registrationToken: String
        package init(repository: String, registrationToken: String) {
            self.repository = repository
            self.registrationToken = registrationToken
        }
    }

    struct Session: Decodable, Sendable {
        let sessionId: UUID
        let messageQueueUrl: URL
        let messageQueueAccessToken: String
        let statistics: Statistics?
    }

    struct Statistics: Decodable, Sendable {
        let totalAssignedJobs: Int
        let totalAvailableJobs: Int?
    }

    struct Offer: Decodable, Sendable {
        let messageType: String
        let runnerRequestId: Int64?
        let runnerId: Int?
    }

    struct Message: Decodable, Sendable {
        let messageId: Int
        let body: String?
        let statistics: Statistics?
    }

    private struct Label: Codable { let name: String; var type = "System" }
    private struct ScaleSet: Decodable { let id: Int; let labels: [Label] }
    private struct Listing<Value: Decodable & Sendable>: Decodable, Sendable { let value: [Value] }
    private struct Credentials: Decodable { let url: URL; let token: String }
    private struct Definition: Encodable {
        let name: String
        let labels: [Label]
        let runnerGroupId = 1
    }
    private struct Runner: Decodable {
        let id: Int
        let runnerScaleSetId: Int?
    }
    struct JIT: Decodable {
        let encodedJITConfig: String
        let runner: Reference
        struct Reference: Decodable { let id: Int }
    }
    private let id: Int
    private let sessionFile: URL
    private struct SavedSession: Codable { let set: Int; let session: UUID }
    let session: Session
    private let endpoint: URL
    private let runnersURL: URL
    private let admin: Access<Credentials>
    private let queue: Access<Session>
    private let transport: GitHubClient.Transport

    /// The service and its message queue issue independent credentials. Concurrent 401s share one renewal.
    private actor Access<Value: Sendable> {
        private var value: Value
        private var generation = 0
        private var renewal: Task<Value, any Error>?
        private let renew: @Sendable (Value) async throws -> Value

        init(_ value: Value, renew: @escaping @Sendable (Value) async throws -> Value) {
            self.value = value
            self.renew = renew
        }

        func perform<Result: Sendable>(_ operation: @Sendable (Value) async throws -> Result) async throws -> Result {
            let used = generation
            do { return try await operation(value) }
            catch GitHubError.response(status: 401, message: _) {
                let refreshed = try await refresh(rejecting: used)
                try Task.checkCancellation()
                return try await operation(refreshed)
            }
        }

        private func refresh(rejecting rejected: Int) async throws -> Value {
            guard generation == rejected else { return value }
            if let renewal { return try await renewal.value }
            let previous = value
            let task = Task { try await renew(previous) }
            renewal = task
            defer { renewal = nil }
            value = try await task.value
            generation += 1
            return value
        }
    }

    static func connect(
        grant: Grant, name: String, labels: [String], owner: String, sessionFile: URL, renewGrant: @escaping @Sendable () async throws -> Grant,
        transport: @escaping GitHubClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Self {
        let credentials = try await credentials(repository: grant.repository, registrationToken: grant.registrationToken, transport: transport)
        let sets = credentials.url.appending(path: "_apis/runtime/runnerscalesets")
        let auth = "Bearer " + credentials.token
        let existing = try await find(name, at: sets, authorization: auth, transport: transport)
        let definition = Definition(name: name, labels: labels.map { Label(name: $0) })
        let id: Int
        if let found = existing {
            id = found.id
            if Set(found.labels.map { $0.name.lowercased() }) != Set(labels.map { $0.lowercased() }) {
                let _: ScaleSet = try await json(versioned(sets.appending(path: String(id))), method: "PATCH",
                    authorization: auth, body: JSONEncoder().encode(definition), transport: transport)
            }
        } else {
            let created: ScaleSet = try await json(versioned(sets), method: "POST", authorization: auth,
                body: JSONEncoder().encode(definition), transport: transport)
            id = created.id
        }
        let endpoint = sets.appending(path: String(id))
        let sessions = endpoint.appending(path: "sessions")
        let body = try JSONEncoder().encode(["ownerName": owner])
        func openSession() async throws -> Session {
            try await json(versioned(sessions), method: "POST", authorization: auth, body: body, transport: transport)
        }
        let session: Session
        do { session = try await openSession() }
        catch let conflict as GitHubError {
            guard case .response(status: 409, message: _) = conflict else { throw conflict }
            let saved: SavedSession
            do { saved = try JSONDecoder().decode(SavedSession.self, from: Data(contentsOf: sessionFile)) }
            catch CocoaError.fileReadNoSuchFile { throw conflict }
            guard saved.set == id else { throw conflict }
            do { try await delete(versioned(sessions.appending(path: saved.session.uuidString)), token: credentials.token, transport: transport) }
            catch GitHubError.response(status: 404, message: _) { }
            session = try await openSession()
        }
        do { try JSONEncoder().encode(SavedSession(set: id, session: session.sessionId)).write(to: sessionFile, options: .atomic) }
        catch {
            let original = error
            do { try await delete(versioned(sessions.appending(path: session.sessionId.uuidString)), token: credentials.token, transport: transport) }
            catch { throw HostSettingsError("\(original.localizedDescription) Could not close the new GitHub session: \(error.localizedDescription)") }
            throw original
        }
        let admin = Access(credentials) { _ in
            let grant = try await renewGrant()
            return try await Self.credentials(repository: grant.repository, registrationToken: grant.registrationToken, transport: transport)
        }
        let queue = Access(session) { old in
            try await admin.perform { credentials in
                try await json(versioned(endpoint.appending(path: "sessions/" + old.sessionId.uuidString)),
                    method: "PATCH", authorization: "Bearer " + credentials.token, transport: transport)
            }
        }
        return Self(id: id, sessionFile: sessionFile, session: session, endpoint: endpoint,
                    runnersURL: credentials.url.appending(path: "_apis/distributedtask/pools/0/agents"),
                    admin: admin, queue: queue, transport: transport)
    }

    private static func credentials(repository: String, registrationToken: String, transport: GitHubClient.Transport) async throws -> Credentials {
        try await json(URL(string: "https://api.github.com/actions/runner-registration")!, method: "POST",
            authorization: "RemoteAuth " + registrationToken,
            body: JSONEncoder().encode(["url": "https://github.com/" + repository, "runner_event": "register"]), transport: transport)
    }

    private static func find(_ name: String, at sets: URL, authorization: String, transport: GitHubClient.Transport) async throws -> ScaleSet? {
        let lookup = versioned(sets).appending(queryItems: [.init(name: "name", value: name), .init(name: "runnerGroupId", value: "1")])
        let listing: Listing<ScaleSet> = try await json(lookup, authorization: authorization, transport: transport)
        return listing.value.first
    }

    /// Removes the scale set when its repository is unlinked.
    static func remove(name: String, repository: String, registrationToken: String, transport: GitHubClient.Transport) async throws {
        let credentials = try await credentials(repository: repository, registrationToken: registrationToken, transport: transport)
        let sets = credentials.url.appending(path: "_apis/runtime/runnerscalesets")
        if let set = try await find(name, at: sets, authorization: "Bearer " + credentials.token, transport: transport) {
            let endpoint = versioned(sets.appending(path: String(set.id)))
            try await delete(endpoint, token: credentials.token, transport: transport)
        }
    }

    /// Poll throughout the job, including while the Mac is full. GitHub can withdraw an offer before a runner starts.
    @MainActor func listen(
        pool: HostExecutionPool,
        hasCapacity: @escaping @MainActor @Sendable () -> Bool,
        workerIsRunning: @escaping @MainActor @Sendable () throws -> Bool,
        whileAuthorized: @escaping @MainActor @Sendable (GitHubRunnerAccess) async throws -> Void,
        begin: @escaping @MainActor @Sendable () throws -> Void, finish: @escaping @MainActor @Sendable () -> Void,
        run: @escaping @MainActor @Sendable (Int32, @MainActor @Sendable (Int) -> Void) async throws -> Void
    ) async throws {
        let jobs = Jobs(pool: pool, set: self, workerIsRunning: workerIsRunning, authorize: { try await whileAuthorized(.acceptJob) }, begin: begin, finish: finish, run: run)
        try await withTaskCancellationHandler {
            do {
                try await jobs.receive([], statistics: session.statistics, recovering: true)
                var last: Int?
                var retryUntil: ContinuousClock.Instant?
                while !jobs.ended {
                    try Task.checkCancellation()
                    do {
                        let capacity = { @MainActor @Sendable in jobs.holdsSlot || hasCapacity() ? 1 : 0 }
                        guard let message = try await next(after: last, capacity: capacity, ended: { jobs.ended }) else {
                            if !jobs.ended {
                                if jobs.holdsSlot {
                                    if !jobs.started, try workerIsRunning() { jobs.workerStarted() }
                                    jobs.checkPickup()
                                } else { try await whileAuthorized(.checkConnection) }
                            }
                            retryUntil = nil
                            continue
                        }
                        let body = message.body ?? ""
                        let events = body.isEmpty ? [] : try JSONDecoder().decode([Offer].self, from: Data(body.utf8))
                        if jobs.holdsSlot, !jobs.started, try workerIsRunning() { jobs.workerStarted() }
                        if let assigned = message.statistics?.totalAssignedJobs { jobs.observeDemand(assigned) }
                        try await jobs.receive(events, statistics: message.statistics)
                        try await acknowledge(message.messageId)
                        last = message.messageId
                        retryUntil = nil
                    } catch {
                        try Task.checkCancellation()
                        guard jobs.holdsSlot, !jobs.ended else { throw error }
                        if jobs.started || (try? workerIsRunning()) == true { throw error }
                        // Keep reading withdrawals while a JIT runner is starting. If the queue stays
                        // unreachable for a minute, retire the unused worker and reconnect.
                        let deadline = retryUntil ?? ContinuousClock.now.advanced(by: .seconds(60))
                        retryUntil = deadline
                        if ContinuousClock.now >= deadline {
                            await jobs.drain(cancel: true)
                            throw error
                        }
                        try await Task.sleep(for: .seconds(2))
                    }
                }
                if let failure = jobs.failure { throw failure }
            } catch {
                // A disconnected managing account stops admissions. A listener or network failure must not kill
                // an accepted job while its runner still owns the checkout.
                await jobs.drain(cancel: Task.isCancelled)
                throw error
            }
        } onCancel: {
            Task { @MainActor in await jobs.drain(cancel: true) }
        }
    }

    @MainActor @Observable fileprivate final class Jobs {
        let pool: HostExecutionPool
        let set: GitHubRunnerScaleSet
        let workerIsRunning: @MainActor @Sendable () throws -> Bool
        let authorize: @MainActor @Sendable () async throws -> Void
        let begin: @MainActor @Sendable () throws -> Void
        let finish: @MainActor @Sendable () -> Void
        let run: @MainActor @Sendable (Int32, @MainActor @Sendable (Int) -> Void) async throws -> Void
        var current: Task<Void, Never>?
        var failure: (any Error)?
        var holdsSlot = false
        var ended = false
        private var request: Int64?
        private var runnerID: Int?
        private(set) var started = false
        private var wasAssigned = false
        private var pickupRead: Task<Void, Never>?
        private var needsPickupRead = false
        private var assignmentRevision = 0

        func observeDemand(_ assigned: Int) {
            if assigned == 0 { checkPickup() }
            else {
                assignmentRevision += 1
                needsPickupRead = false
            }
        }

        /// Keep a withdrawal observed during acquisition or an outstanding read until it can be verified.
        func checkPickup() {
            needsPickupRead = true
            startPickupReadIfNeeded()
        }

        private func startPickupReadIfNeeded() {
            guard needsPickupRead, holdsSlot, wasAssigned, !started, !ended, pickupRead == nil else { return }
            pickupRead = Task {
                defer { pickupRead = nil }
                var deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while needsPickupRead && !Task.isCancelled && holdsSlot && !started && !ended {
                    needsPickupRead = false
                    let revision = assignmentRevision
                    do {
                        let demand = try await set.currentStatistics()
                        guard !Task.isCancelled, holdsSlot, !started, !ended else { return }
                        deadline = .now.advanced(by: .seconds(60))
                        guard assignmentRevision == revision else { continue }
                        if try workerIsRunning() { started = true }
                        else if demand?.totalAssignedJobs == 0 { current?.cancel(); return }
                    } catch {
                        guard !Task.isCancelled, holdsSlot, !started, !ended else { return }
                        if assignmentRevision != revision {
                            deadline = .now.advanced(by: .seconds(60))
                            continue
                        }
                        if (try? workerIsRunning()) == true { started = true; return }
                        if ContinuousClock.now >= deadline { current?.cancel(); return }
                        needsPickupRead = true
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        if assignmentRevision != revision { deadline = .now.advanced(by: .seconds(60)) }
                    }
                }
            }
        }

        func workerStarted() { started = true }

        init(pool: HostExecutionPool, set: GitHubRunnerScaleSet, workerIsRunning: @escaping @MainActor @Sendable () throws -> Bool,
             authorize: @escaping @MainActor @Sendable () async throws -> Void,
             begin: @escaping @MainActor @Sendable () throws -> Void, finish: @escaping @MainActor @Sendable () -> Void, run: @escaping @MainActor @Sendable (Int32, @MainActor @Sendable (Int) -> Void) async throws -> Void) {
            self.pool = pool
            self.set = set
            self.workerIsRunning = workerIsRunning
            self.authorize = authorize
            self.begin = begin
            self.finish = finish
            self.run = run
        }

        /// A session serves one worker. On exit a new session reads GitHub's current demand, even if
        /// individual job messages were delayed, omitted, or delivered while the worker was shutting down.
        func receive(_ events: [Offer], statistics: Statistics?, recovering: Bool = false) async throws {
            let completed = Set(events.filter { $0.messageType == "JobCompleted" }.compactMap(\.runnerRequestId))
            let assigned = events.first { $0.messageType == "JobAssigned" && $0.runnerRequestId.map { !completed.contains($0) } == true }
            if current != nil {
                if request == nil { request = assigned?.runnerRequestId }
                if assigned != nil || (statistics?.totalAssignedJobs ?? 0) > 0 { wasAssigned = true }
                for event in events where event.messageType == "JobStarted" && ((runnerID != nil && event.runnerId == runnerID) || (request != nil && request == event.runnerRequestId)) {
                    request = event.runnerRequestId
                    started = true
                }
                // A completion naming our worker also confirms it ran, even if its start event was truncated.
                if let runnerID, events.contains(where: { $0.messageType == "JobCompleted" && $0.runnerId == runnerID }) { started = true }
                if !started, let request, completed.contains(request) { current?.cancel() }
                else if !started, !holdsSlot, statistics?.totalAssignedJobs == 0,
                        wasAssigned || statistics?.totalAvailableJobs == 0 { current?.cancel() }
                return
            }
            if assigned != nil || (statistics?.totalAssignedJobs ?? 0) > 0 {
                start(assigned?.runnerRequestId, assigned: true)
            } else if let offer = events.first(where: {
                $0.messageType == "JobAvailable" && $0.runnerRequestId.map { !completed.contains($0) } == true
            })?.runnerRequestId {
                start(offer, assigned: false)
            } else if (statistics?.totalAvailableJobs ?? 0) > 0 || (recovering && statistics == nil) {
                // Acknowledging an availability notification does not acquire its job. GitHub keeps the
                // outstanding offers here, including offers this host saw before a pause or restart.
                if let offer = try await set.availableJob() { start(offer, assigned: false) }
            }
        }

        func drain(cancel: Bool) async {
            if cancel || !holdsSlot { current?.cancel() }
            await current?.value
        }

        private func start(_ id: Int64?, assigned: Bool) {
            request = id
            wasAssigned = assigned
            current = Task {
                do {
                    try await pool.withSlotDescriptor { slot in try await self.accept(id, assigned: assigned, slot: slot) }
                } catch {
                    if !Task.isCancelled { failure = error }
                }
                ended = true
                pickupRead?.cancel()
                await pickupRead?.value
            }
        }

        private func accept(_ id: Int64?, assigned: Bool, slot: Int32) async throws {
            try await authorize()
            try Task.checkCancellation()
            try begin()
            holdsSlot = true
            defer { holdsSlot = false; finish() }
            if !assigned, let id {
                guard try await set.acquire(id) else { return }
                wasAssigned = true
            }
            startPickupReadIfNeeded()
            try await run(slot) { self.runnerID = $0 }
            if !started, !Task.isCancelled, let demand = try await set.currentStatistics(), demand.totalAssignedJobs > 0 {
                throw HostSettingsError("The GitHub runner exited while a job was still awaiting pickup. See the runner log.")
            }
        }
    }

    @MainActor private func next(after last: Int?, capacity: @escaping @MainActor @Sendable () -> Int,
                                 ended: @escaping @MainActor @Sendable () -> Bool) async throws -> Message? {
        let advertised = capacity()
        return try await withThrowingTaskGroup(of: Message?.self) { group in
            group.addTask { try await poll(after: last, capacity: advertised) }
            group.addTask {
                await Self.waitForPollChange { capacity() != advertised || ended() }
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    @MainActor private static func waitForPollChange(_ changed: @escaping @MainActor @Sendable () -> Bool) async {
        // Reissue the long poll when the host monitor sees a slot open or fill.
        for await value in Observations(changed) where value { return }
    }

    private func poll(after last: Int?, capacity: Int) async throws -> Message? {
        try await queue.perform { session in try await poll(session, after: last, capacity: capacity) }
    }

    private func poll(_ session: Session, after last: Int?, capacity: Int) async throws -> Message? {
        var url = session.messageQueueUrl
        if let last { url = url.appending(queryItems: [.init(name: "lastMessageId", value: String(last))]) }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(String(capacity), forHTTPHeaderField: "X-ScaleSetMaxCapacity")
        request.setValue("Bearer " + session.messageQueueAccessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json; api-version=6.0-preview", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.send(request, transport: transport)
        if response.statusCode == 202 { return nil }
        return try JSONDecoder().decode(Message.self, from: data)
    }

    private func currentStatistics() async throws -> Statistics? {
        struct State: Decodable { let statistics: Statistics? }
        let url = Self.versioned(endpoint).appending(queryItems: [.init(name: "includeStatistics", value: "true")])
        let state: State = try await admin.perform { credentials in
            try await Self.json(url, authorization: "Bearer " + credentials.token, transport: transport)
        }
        return state.statistics
    }

    private func availableJob() async throws -> Int64? {
        struct Available: Decodable { let runnerRequestId: Int64 }
        return try await admin.perform { credentials in
            var request = URLRequest(url: Self.versioned(endpoint.appending(path: "acquirablejobs")))
            request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await Self.send(request, transport: transport)
            if response.statusCode == 204 { return nil }
            return try JSONDecoder().decode(Listing<Available>.self, from: data).value.first?.runnerRequestId
        }
    }

    func acquire(_ job: Int64) async throws -> Bool {
        let jobs: Listing<Int64> = try await queue.perform { session in
            try await Self.json(Self.versioned(endpoint.appending(path: "acquirejobs")), method: "POST",
                authorization: "Bearer " + session.messageQueueAccessToken,
                body: JSONEncoder().encode([job]), transport: transport)
        }
        return jobs.value.contains(job)
    }

    func configuration(name: String, workFolder: String) async throws -> JIT {
        let url = Self.versioned(endpoint.appending(path: "generatejitconfig"))
        let body = try JSONEncoder().encode(["name": name, "workFolder": workFolder])
        do { return try await admin.perform { credentials in try await Self.json(url, method: "POST", authorization: "Bearer " + credentials.token, body: body, transport: transport) } }
        catch GitHubError.response(status: 409, message: _) {
            // The host's ownership lock outlives its helpers. A previous process can leave an unused JIT registration.
            let list: Listing<Runner> = try await admin.perform { credentials in
                try await Self.json(Self.versioned(runnersURL).appending(queryItems: [.init(name: "agentName", value: name)]),
                    authorization: "Bearer " + credentials.token, transport: transport)
            }
            guard let runner = list.value.first(where: { $0.runnerScaleSetId == id }) else {
                throw HostSettingsError("Another runner already uses the GitHub job runner name \(name).")
            }
            try await removeRunner(runner.id)
            return try await admin.perform { credentials in try await Self.json(url, method: "POST", authorization: "Bearer " + credentials.token, body: body, transport: transport) }
        }
    }

    func removeRunner(_ id: Int) async throws {
        do {
            try await admin.perform { credentials in
                try await Self.delete(Self.versioned(runnersURL.appending(path: String(id))), token: credentials.token, transport: transport)
            }
        }
        catch GitHubError.response(status: 404, message: _) { }
    }

    func acknowledge(_ message: Int) async throws {
        try await queue.perform { session in
            try await Self.delete(session.messageQueueUrl.appending(path: String(message)), token: session.messageQueueAccessToken, transport: transport)
        }
    }

    func close() async throws {
        do {
            try await admin.perform { credentials in
                try await Self.delete(Self.versioned(endpoint.appending(path: "sessions/" + session.sessionId.uuidString)), token: credentials.token, transport: transport)
            }
        } catch GitHubError.response(status: 404, message: _) { }
        do { try FileManager.default.removeItem(at: sessionFile) } catch CocoaError.fileNoSuchFile { }
    }

    private static func delete(_ url: URL, token: String, transport: GitHubClient.Transport) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        _ = try await Self.send(request, transport: transport)
    }

    private static func versioned(_ url: URL) -> URL {
        url.appending(queryItems: [.init(name: "api-version", value: "6.0-preview")])
    }

    private static func json<Value: Decodable>(
        _ url: URL, method: String = "GET", authorization: String, body: Data? = nil,
        transport: GitHubClient.Transport
    ) async throws -> Value {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, _) = try await send(request, transport: transport)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func send(_ request: URLRequest, transport: GitHubClient.Transport) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.response(status: response.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        }
        return (data, response)
    }
}
