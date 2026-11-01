import Foundation
import Network
import Observation

/// This Mac's pairing with the host that manages it, and the connections that host makes.
@MainActor @Observable
final class HostManagement {
    /// How long this Mac waits to pair, in seconds.
    static let pairingDuration: TimeInterval = 300

    struct PairingWindow: Equatable {
        let id = UUID()
        let expiresAt: Date
        /// The managing host asking to pair. One host can ask at a time.
        var request: PairingPrompt?
        /// The listening port, for connections that do not use Bonjour.
        var port: NWEndpoint.Port?
    }

    /// A managing host's request to pair, which the person allows after checking that both Macs show the same code.
    struct PairingPrompt: Equatable {
        /// The request's connection.
        let id: UUID
        let managerName: String
        /// `nil` until the Macs exchange keys.
        var code: String?
        var isAllowed = false
    }

    /// What this Mac keeps about being managed.
    struct Record: Codable {
        /// Identifies this Mac to managing hosts across pairings.
        let hostID: UUID
        var manager: HostPairing?
    }

    private let store: any SecretStore
    private let name: String
    private let advertises: Bool
    private let hostID: UUID
    private(set) var manager: HostPairing?
    private(set) var pairingWindow: PairingWindow?
    /// The management listener's port, for connections that do not use Bonjour.
    private(set) var managementPort: NWEndpoint.Port?
    /// Why the last pairing window closed without pairing.
    private(set) var pairingMessage: String?
    private(set) var errorMessage: String?
    /// Answers the managing host's requests to read and change this Mac's settings.
    @ObservationIgnored weak var settings: HostSettingsModel?
    /// Outlives a window that closed when the Macs paired, until the managing host gets the reply.
    private var pairingTask: (window: UUID, task: Task<Void, Never>)?
    private var decision: (request: UUID, continuation: CheckedContinuation<Void, any Error>)?
    private var managementTask: Task<Void, Never>?

    /// - Parameter advertises: Whether listeners register Bonjour services. Tests connect to the listening ports instead.
    init(store: any SecretStore, name: String, advertises: Bool = true) {
        self.store = store
        self.name = name
        self.advertises = advertises
        do {
            let record = try store.read().map { try JSONDecoder().decode(Record.self, from: $0) }
            hostID = record?.hostID ?? UUID()
            manager = record?.manager
        } catch {
            hostID = UUID()
            errorMessage = "Could not read this Mac's pairing: \(error.localizedDescription)"
        }
    }

    /// Accepts the managing host's connections, if this Mac is paired.
    func start() {
        guard let manager, managementTask == nil else { return }
        let txtRecord = NWTXTRecord([HostLink.pairingKeyName: manager.id.uuidString])
        managementTask = Task {
            do {
                try await HostLink.listen(
                    key: manager.symmetricKey, identity: manager.id.uuidString,
                    advertising: advertises ? .bonjour(name: name, type: HostLink.managementService, txtRecord: txtRecord) : nil,
                    ready: { port in await self.managementListenerIsReady(port, for: manager.id) }
                ) { request, reply in
                    switch request {
                    case .settings(let request):
                        guard let settings = await self.settings else {
                            try await reply(.refused("\(self.name) cannot share its settings."))
                            return
                        }
                        try await reply(await settings.answer(request))
                    case .unpair:
                        // Replying after the pairing is removed keeps the host from forgetting a Mac that still accepts it.
                        if case .failure(let error) = await self.forget(manager.id) {
                            try await reply(.refused("\(self.name) could not remove the pairing: \(error.localizedDescription)"))
                            return
                        }
                        // The pairing is already removed, so a lost reply does not keep it.
                        try? await reply(.unpaired)
                        await self.stopAcceptingConnections()
                    }
                }
            } catch is CancellationError {
            } catch {
                showManagementFailure(error, for: manager.id)
            }
        }
    }

    func shutDown() async {
        let tasks = [pairingTask?.task, managementTask]
        pairingTask = nil
        managementTask = nil
        for task in tasks { task?.cancel() }
        for task in tasks { await task?.value }
    }

    /// Waits for a managing host to ask to pair.
    func allowManagement() {
        guard pairingWindow == nil else { return }
        // A window that closed when the Macs paired or the person refused may still be sending its last reply.
        pairingTask?.task.cancel()
        let window = PairingWindow(expiresAt: .now.addingTimeInterval(Self.pairingDuration))
        pairingWindow = window
        pairingMessage = nil
        let task = Task {
            do {
                try await withThrowingTaskGroup { group in
                    group.addTask {
                        try await HostLink.acceptPairing(
                            name: self.name, hostID: self.hostID,
                            advertising: self.advertises ? .bonjour(name: self.name, type: HostLink.pairingService) : nil,
                            ready: { port in await self.pairingListenerIsReady(port, window: window.id) },
                            begin: { request, managerName in
                                try await self.takeRequest(request, from: managerName, window: window.id)
                            },
                            allow: { request, code in try await self.askToAllow(request, code: code) },
                            save: { pairing in try await self.pair(with: pairing, window: window.id) },
                            ended: { request in await self.pairingRequestEnded(request, window: window.id) }
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(Self.pairingDuration))
                        await self.closePairingWindow(window.id, message: "No managing Mac paired in time.")
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

    /// Allows the managing host that asks to pair, after the person checks that both Macs show the same code.
    func allowPairing() {
        guard var request = pairingWindow?.request, request.code != nil, !request.isAllowed else { return }
        request.isAllowed = true
        pairingWindow?.request = request
        decide(request.id, .success(()))
    }

    /// Refuses the managing host that asks to pair and stops waiting, because an unexpected request can come from
    /// someone else on the network.
    func refusePairing() {
        guard let request = pairingWindow?.request else { return }
        // The listener stops once the managing host gets the refusal.
        pairingWindow = nil
        pairingMessage = "You did not allow \(request.managerName) to manage this Mac."
        decide(request.id, .failure(PairingRefusal("\(name) did not allow the pairing.")))
    }

    /// Forgets the managing host. It can no longer connect until the Macs pair again.
    func stopManagement() {
        guard let manager, case .success = forget(manager.id) else { return }
        stopAcceptingConnections()
    }

    /// Takes one request at a time, because each request lets the managing host try for a matching code.
    private func takeRequest(_ request: UUID, from managerName: String, window: UUID) throws {
        guard pairingWindow?.id == window else { throw PairingRefusal("\(name) is no longer waiting to pair.") }
        guard pairingWindow?.request == nil else { throw PairingRefusal("\(name) is confirming another pairing.") }
        pairingWindow?.request = PairingPrompt(id: request, managerName: managerName)
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

    /// Keeps a pairing that the person allowed and the managing host confirmed.
    private func pair(with pairing: HostPairing, window: UUID) throws {
        // Closing the window here lets only one managing host pair through it.
        guard pairingWindow?.id == window else { throw PairingRefusal("\(name) is no longer waiting to pair.") }
        do {
            try store.write(JSONEncoder().encode(Record(hostID: hostID, manager: pairing)))
        } catch {
            errorMessage = "Could not save the pairing: \(error.localizedDescription)"
            throw PairingRefusal("\(name) could not save the pairing.")
        }
        pairingWindow = nil
        // A Mac has one managing host, so a new pairing replaces the previous one.
        managementTask?.cancel()
        managementTask = nil
        managementPort = nil
        manager = pairing
        start()
    }

    private func pairingRequestEnded(_ request: UUID, window: UUID) {
        decide(request, .failure(CancellationError()))
        if let prompt = pairingWindow?.request, prompt.id == request {
            // Another request could try for a matching code again, so pairing stops instead.
            closePairingWindow(window, message: "Pairing stopped because \(prompt.managerName) did not finish pairing.")
        } else if pairingWindow == nil, pairingTask?.window == window {
            // The window closed when the Macs paired or the person refused, and the managing host now has the reply.
            pairingTask?.task.cancel()
            pairingTask = nil
        }
    }

    private func forget(_ id: HostPairing.ID) -> Result<Void, any Error> {
        guard manager?.id == id else { return .success(()) }
        do {
            try store.write(JSONEncoder().encode(Record(hostID: hostID, manager: nil)))
        } catch {
            errorMessage = "Could not remove the pairing: \(error.localizedDescription)"
            return .failure(error)
        }
        manager = nil
        errorMessage = nil
        return .success(())
    }

    private func stopAcceptingConnections() {
        // A pairing made meanwhile replaced the listener already.
        guard manager == nil else { return }
        managementTask?.cancel()
        managementTask = nil
        managementPort = nil
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

    private func managementListenerIsReady(_ port: NWEndpoint.Port, for id: HostPairing.ID) {
        guard manager?.id == id else { return }
        managementPort = port
    }

    private func showManagementFailure(_ error: any Error, for id: HostPairing.ID) {
        guard manager?.id == id else { return }
        managementTask = nil
        managementPort = nil
        errorMessage = "Could not accept connections from \(manager?.name ?? "the managing host"): \(error.localizedDescription)"
    }
}
