import Foundation
import Network
import Observation

/// This Mac's pairings with the host that manages it and with the dashboards that show it, and the connections they
/// make.
@MainActor @Observable
final class HostManagement {
    /// How long this Mac waits to pair, in seconds.
    static let pairingDuration: TimeInterval = 300

    struct PairingWindow: Equatable {
        let id = UUID()
        /// What the Mac that pairs through this window may do.
        let role: PairingRole
        let expiresAt: Date
        /// The Mac asking to pair. One Mac can ask at a time.
        var request: PairingPrompt?
        /// The listening port, for connections that do not use Bonjour.
        var port: NWEndpoint.Port?
    }

    /// A Mac's request to pair, which the person allows after checking that both Macs show the same code.
    struct PairingPrompt: Equatable {
        /// The request's connection.
        let id: UUID
        let requesterName: String
        /// `nil` until the Macs exchange keys.
        var code: String?
        var isAllowed = false
    }

    /// What this Mac keeps about the Macs paired with it.
    struct Record: Codable {
        /// Identifies this Mac to the Macs that pair with it, across pairings.
        let hostID: UUID
        var manager: HostPairing?
        var dashboards: [HostPairing] = []
    }

    private let store: any SecretStore
    private let name: String
    private let advertises: Bool
    private let version: Int
    private let hostID: UUID
    private(set) var manager: HostPairing?
    /// The Macs that show this Mac in their window. They change its settings and leave its runners to this Mac or
    /// its managing host.
    private(set) var dashboards: [HostPairing] = []
    private(set) var pairingWindow: PairingWindow?
    /// Each pairing's listening port, for connections that do not use Bonjour.
    private(set) var ports: [HostPairing.ID: NWEndpoint.Port] = [:]
    /// The paired Macs whose last request came from another version of the app. This Mac does not answer them.
    private(set) var versionMismatches: [HostPairing.ID: VersionMismatch] = [:]
    /// Why the last pairing window closed without pairing.
    private(set) var pairingMessage: String?
    private(set) var errorMessage: String?
    /// Answers the paired Macs' requests to read and change this Mac's settings and runners.
    @ObservationIgnored weak var settings: HostSettingsModel?
    /// Outlives a window that closed when the Macs paired, until the asking Mac gets the reply.
    private var pairingTask: (window: UUID, task: Task<Void, Never>)?
    private var decision: (request: UUID, continuation: CheckedContinuation<Void, any Error>)?
    private var listeners: [HostPairing.ID: Task<Void, Never>] = [:]

    /// The managing host's listening port.
    var managementPort: NWEndpoint.Port? { manager.flatMap { ports[$0.id] } }

    /// - Parameters:
    ///   - advertises: Whether listeners register Bonjour services. Tests connect to the listening ports instead.
    ///   - version: The version of this Mac's messages.
    init(store: any SecretStore, name: String, advertises: Bool = true, version: Int = HostLink.version) {
        self.store = store
        self.name = name
        self.advertises = advertises
        self.version = version
        do {
            let record = try store.read().map { try JSONDecoder().decode(Record.self, from: $0) }
            hostID = record?.hostID ?? UUID()
            manager = record?.manager
            dashboards = record?.dashboards ?? []
        } catch {
            hostID = UUID()
            errorMessage = "Could not read this Mac's pairing: \(error.localizedDescription)"
        }
    }

    /// Accepts the connections of the Macs paired with this Mac.
    func start() {
        if let manager { listen(to: manager, as: .manager) }
        for dashboard in dashboards { listen(to: dashboard, as: .dashboard) }
    }

    private func listen(to pairing: HostPairing, as role: PairingRole) {
        guard listeners[pairing.id] == nil else { return }
        let txtRecord = NWTXTRecord([HostLink.pairingKeyName: pairing.id.uuidString, HostLink.versionKeyName: String(version)])
        // This Mac advertises one service for each pairing, and a service name has to be its only one of that type.
        let serviceName = role == .manager ? name : pairing.id.uuidString
        listeners[pairing.id] = Task {
            do {
                try await HostLink.listen(
                    key: pairing.symmetricKey, identity: pairing.id.uuidString, version: version,
                    advertising: advertises ? .bonjour(name: serviceName, type: HostLink.managementService, txtRecord: txtRecord) : nil,
                    ready: { port in await self.listenerIsReady(port, for: pairing.id) },
                    connected: { version in await self.connected(pairing.id, version: version) }
                ) { request, reply in
                    switch request {
                    case .settings(let request):
                        guard let settings = await self.settings else {
                            try await reply(.refused("\(self.name) cannot share its settings."))
                            return
                        }
                        let answer = await settings.answer(request)
                        // The change is saved, so what follows it does not depend on the reply arriving.
                        let delivery: Result<Void, any Error>
                        do { delivery = .success(try await reply(answer)) } catch { delivery = .failure(error) }
                        // A managing host registers runners for a changed job limit itself. After a dashboard's
                        // change this Mac does, as it does after its own Apply.
                        if role == .dashboard, case .settings = answer, case .configurePool(let changes) = request,
                           changes.maximumConcurrentJobs != nil {
                            await settings.github.synchronize()
                        }
                        // The paired Mac has the reply, or its connection is gone.
                        if case .restart = request, case .settings = answer { await settings.restart() }
                        try delivery.get()
                    case .github(let request):
                        // A managing host registers this Mac's runners from its own sign-in and selection.
                        guard role == .dashboard, let github = await self.settings?.github else {
                            try await reply(.refused(role == .dashboard
                                ? "\(self.name) cannot share its GitHub settings."
                                : "\(self.name) shares its GitHub settings only with a dashboard."))
                            return
                        }
                        let answer = await github.answer(request)
                        // The selection is saved, so registering its runners does not depend on the reply arriving.
                        let delivery: Result<Void, any Error>
                        do { delivery = .success(try await reply(answer)) } catch { delivery = .failure(error) }
                        if case .applySelection = request, case .github = answer { await github.synchronizeDashboardSelection() }
                        try delivery.get()
                    case .macs(let request):
                        // The Macs that this Mac manages accept it, and a dashboard reaches them through it.
                        guard role == .dashboard, let settings = await self.settings else {
                            try await reply(.refused(role == .dashboard
                                ? "\(self.name) cannot share its Macs."
                                : "\(self.name) shares its Macs only with a dashboard."))
                            return
                        }
                        let answer = await settings.managedMacsRelay.answer(request, from: pairing.id)
                        // The limit is saved, so registering runners for it does not depend on the reply arriving.
                        let delivery: Result<Void, any Error>
                        do { delivery = .success(try await reply(answer.reply)) } catch { delivery = .failure(error) }
                        if answer.limitChanged { await settings.github.synchronize() }
                        try delivery.get()
                    case .runners(let request):
                        guard role == .manager, let github = await self.settings?.github else {
                            try await reply(.refused(role == .manager
                                ? "\(self.name) cannot share its runners."
                                : "\(self.name) changes its runners only for its managing Mac."))
                            return
                        }
                        try await reply(await github.answer(request))
                    case .unpair:
                        // Replying after the pairing is removed keeps the other Mac from forgetting a Mac that still
                        // accepts it.
                        if case .failure(let error) = await self.forget(pairing.id) {
                            try await reply(.refused("\(self.name) could not remove the pairing: \(error.localizedDescription)"))
                            return
                        }
                        // The pairing is already removed, so a lost reply does not keep it.
                        try? await reply(.unpaired)
                        await self.stopListening(to: pairing.id)
                    }
                }
            } catch is CancellationError {
            } catch {
                showListeningFailure(error, for: pairing)
            }
        }
    }

    func shutDown() async {
        let tasks = [pairingTask?.task].compactMap { $0 } + listeners.values
        pairingTask = nil
        listeners = [:]
        ports = [:]
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    /// Waits for a managing host to ask to pair.
    func allowManagement() { waitToPair(as: .manager) }

    /// Waits for a dashboard to ask to pair.
    func allowDashboard() { waitToPair(as: .dashboard) }

    private func waitToPair(as role: PairingRole) {
        guard pairingWindow == nil else { return }
        // A window that closed when the Macs paired or the person refused may still be sending its last reply.
        pairingTask?.task.cancel()
        let window = PairingWindow(role: role, expiresAt: .now.addingTimeInterval(Self.pairingDuration))
        pairingWindow = window
        pairingMessage = nil
        let txtRecord = NWTXTRecord([HostLink.roleKeyName: role.rawValue, HostLink.versionKeyName: String(version)])
        let task = Task {
            do {
                try await withThrowingTaskGroup { group in
                    group.addTask {
                        try await HostLink.acceptPairing(
                            name: self.name, hostID: self.hostID, role: role, version: self.version,
                            advertising: self.advertises
                                ? .bonjour(name: self.name, type: HostLink.pairingService, txtRecord: txtRecord) : nil,
                            ready: { port in await self.pairingListenerIsReady(port, window: window.id) },
                            begin: { request, requesterName in
                                try await self.takeRequest(request, from: requesterName, window: window.id)
                            },
                            allow: { request, code in try await self.askToAllow(request, code: code) },
                            save: { pairing in try await self.pair(with: pairing, window: window.id) },
                            ended: { request in await self.pairingRequestEnded(request, window: window.id) }
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(Self.pairingDuration))
                        await self.closePairingWindow(
                            window.id, message: role == .manager ? "No managing Mac paired in time." : "No dashboard paired in time."
                        )
                    }
                    try await group.next()
                }
            } catch is CancellationError {
            } catch {
                closePairingWindow(window.id, message: "Could not wait for pairing: \(error.localizedDescription)")
            }
        }
        pairingTask = (window.id, task)
    }

    func cancelPairing() {
        guard let window = pairingWindow else { return }
        closePairingWindow(window.id, message: nil)
    }

    /// Allows the Mac that asks to pair, after the person checks that both Macs show the same code.
    func allowPairing() {
        guard var request = pairingWindow?.request, request.code != nil, !request.isAllowed else { return }
        request.isAllowed = true
        pairingWindow?.request = request
        decide(request.id, .success(()))
    }

    /// Refuses the Mac that asks to pair and stops waiting, because an unexpected request can come from someone else
    /// on the network.
    func refusePairing() {
        guard let window = pairingWindow, let request = window.request else { return }
        // The listener stops once the asking Mac gets the refusal.
        pairingWindow = nil
        pairingMessage = window.role == .manager
            ? "You did not allow \(request.requesterName) to manage this Mac."
            : "You did not allow \(request.requesterName) to show this Mac."
        decide(request.id, .failure(PairingRefusal("\(name) did not allow the pairing.")))
    }

    /// Forgets the managing host. It can no longer connect until the Macs pair again.
    func stopManagement() {
        guard let manager, case .success = forget(manager.id) else { return }
        stopListening(to: manager.id)
    }

    /// Forgets a dashboard. It can no longer connect until the Macs pair again.
    func removeDashboard(_ id: HostPairing.ID) {
        guard dashboards.contains(where: { $0.id == id }), case .success = forget(id) else { return }
        stopListening(to: id)
    }

    /// Takes one request at a time, because each request lets the asking Mac try for a matching code.
    private func takeRequest(_ request: UUID, from requesterName: String, window: UUID) throws {
        guard pairingWindow?.id == window else { throw PairingRefusal("\(name) is no longer waiting to pair.") }
        guard pairingWindow?.request == nil else { throw PairingRefusal("\(name) is confirming another pairing.") }
        pairingWindow?.request = PairingPrompt(id: request, requesterName: requesterName)
    }

    private func askToAllow(_ request: UUID, code: String) async throws {
        guard pairingWindow?.request?.id == request else { throw PairingRefusal("\(name) is no longer waiting to pair.") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                decision = (request, continuation)
                pairingWindow?.request?.code = code
            }
        } onCancel: {
            Task { @MainActor in self.decide(request, .failure(CancellationError())) }
        }
    }

    private func decide(_ request: UUID, _ result: Result<Void, any Error>) {
        guard let decision, decision.request == request else { return }
        self.decision = nil
        decision.continuation.resume(with: result)
    }

    /// Keeps a pairing that the person allowed and the asking Mac confirmed.
    private func pair(with pairing: HostPairing, window: UUID) throws {
        // Closing the window here lets only one Mac pair through it.
        guard let open = pairingWindow, open.id == window else { throw PairingRefusal("\(name) is no longer waiting to pair.") }
        var record = Record(hostID: hostID, manager: manager, dashboards: dashboards)
        switch open.role {
        case .manager: record.manager = pairing
        case .dashboard: record.dashboards.append(pairing)
        }
        do {
            try store.write(JSONEncoder().encode(record))
        } catch {
            errorMessage = "Could not save the pairing: \(error.localizedDescription)"
            throw PairingRefusal("\(name) could not save the pairing.")
        }
        pairingWindow = nil
        // A Mac has one managing host, so a new one replaces the previous one. Dashboards stay as they are.
        if open.role == .manager, let previous = manager { stopListening(to: previous.id) }
        manager = record.manager
        dashboards = record.dashboards
        listen(to: pairing, as: open.role)
    }

    private func pairingRequestEnded(_ request: UUID, window: UUID) {
        decide(request, .failure(CancellationError()))
        if let prompt = pairingWindow?.request, prompt.id == request {
            // Another request could try for a matching code again, so pairing stops instead.
            closePairingWindow(window, message: "Pairing stopped because \(prompt.requesterName) did not finish pairing.")
        } else if pairingWindow == nil, pairingTask?.window == window {
            // The window closed when the Macs paired or the person refused, and the asking Mac now has the reply.
            pairingTask?.task.cancel()
            pairingTask = nil
        }
    }

    private func forget(_ id: HostPairing.ID) -> Result<Void, any Error> {
        var record = Record(hostID: hostID, manager: manager, dashboards: dashboards)
        if record.manager?.id == id { record.manager = nil }
        record.dashboards.removeAll { $0.id == id }
        guard record.manager != manager || record.dashboards != dashboards else { return .success(()) }
        do {
            try store.write(JSONEncoder().encode(record))
        } catch {
            errorMessage = "Could not remove the pairing: \(error.localizedDescription)"
            return .failure(error)
        }
        manager = record.manager
        dashboards = record.dashboards
        errorMessage = nil
        return .success(())
    }

    private func stopListening(to id: HostPairing.ID) {
        listeners.removeValue(forKey: id)?.cancel()
        ports[id] = nil
        versionMismatches[id] = nil
    }

    /// Records whether a paired Mac's request came from this Mac's version of the app.
    private func connected(_ id: HostPairing.ID, version: Int) {
        guard listeners[id] != nil else { return }
        versionMismatches[id] = version == self.version ? nil : VersionMismatch(theirs: version, own: self.version)
    }

    private func closePairingWindow(_ window: UUID, message: String?) {
        guard pairingTask?.window == window else { return }
        pairingTask?.task.cancel()
        pairingTask = nil
        guard pairingWindow?.id == window else { return }
        pairingWindow = nil
        pairingMessage = message
    }

    private func pairingListenerIsReady(_ port: NWEndpoint.Port, window: UUID) {
        guard pairingWindow?.id == window else { return }
        pairingWindow?.port = port
    }

    private func listenerIsReady(_ port: NWEndpoint.Port, for id: HostPairing.ID) {
        guard listeners[id] != nil else { return }
        ports[id] = port
    }

    private func showListeningFailure(_ error: any Error, for pairing: HostPairing) {
        guard manager == pairing || dashboards.contains(pairing) else { return }
        listeners[pairing.id] = nil
        ports[pairing.id] = nil
        errorMessage = "Could not accept connections from \(pairing.name): \(error.localizedDescription)"
    }
}

extension HostManagement.Record {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        manager = try container.decodeIfPresent(HostPairing.self, forKey: .manager)
        // Records saved before dashboards have none.
        dashboards = try container.decodeIfPresent([HostPairing].self, forKey: .dashboards) ?? []
    }
}
