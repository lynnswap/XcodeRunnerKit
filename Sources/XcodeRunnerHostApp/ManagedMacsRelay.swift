import Foundation

/// Reads or changes the Macs that a host manages, for a dashboard. The host answers with those Macs afterwards. The
/// dashboard has no pairing with them, so each request reaches them through the host's own pairing.
enum ManagedMacsRequest: Codable, Sendable {
    /// - Parameter refreshing: A Mac whose settings the host reads again first, because the dashboard shows its pane.
    case read(refreshing: HostPairing.ID?)
    case configurePool(PoolSettingsDraft.Changes, mac: HostPairing.ID)
    case saveStorage(directory: String, mac: HostPairing.ID)
    case saveXcode(developerDirectory: String?, mac: HostPairing.ID)
    case setPaused(Bool, mac: HostPairing.ID)
    case restart(mac: HostPairing.ID)
    /// Ends the pairing between the host and a Mac.
    case remove(mac: HostPairing.ID)
    /// Lists the Macs that wait to pair with the host. The host keeps looking while dashboards keep asking.
    case discover
    /// Starts pairing the host with a waiting Mac. Later reads carry the code to confirm, and the result.
    ///
    /// - Parameter attempt: Names this pairing, so that the dashboard reads and cancels only its own.
    case pair(waitingMac: WaitingMac.ID, attempt: UUID)
    /// Confirms that the Mac being paired as `attempt` shows the same code as the report.
    case confirmCode(attempt: UUID)
    /// Stops the pairing that the dashboard started as `attempt`, if the host is still pairing for it.
    case cancelPairing(attempt: UUID)
}

/// The Macs that a host manages, as its own window lists them and as it sends them to a dashboard.
struct ManagedMacsReport: Codable, Equatable, Sendable {
    struct Mac: Codable, Equatable, Identifiable, Sendable {
        let id: HostPairing.ID
        let name: String
        let status: PairedMacs.Status
        /// The settings that the host last read from the Mac.
        let settings: HostSettingsReport?
        let readAt: Date?
    }

    /// Names the host process that counts `revision`, which starts again when the host restarts.
    let session: UUID
    /// Orders one session's reports by when the host made them. Answers can arrive in another order, and an answer to
    /// a read can be older than the answer to a change that was sent before it.
    let revision: Int
    let macs: [Mac]
    let message: String?
    /// Whether the host can pair with another Mac. A host that another Mac manages cannot.
    let canAddMacs: Bool
    let waitingMacs: [WaitingMac]
    let discoveryMessage: String?
    /// The last pairing that the dashboard reading this report started.
    let pairingAttempt: UUID?
    /// The code of `pairingAttempt`, for that dashboard to compare and confirm.
    let codeConfirmation: PairedMacs.CodeConfirmation?
    /// Whether the host is still pairing for `pairingAttempt`.
    let isPairing: Bool
    /// The Mac that `pairingAttempt` added.
    let pairedMac: ListedMac?
    /// Why `pairingAttempt` failed.
    let pairingError: String?
}

/// Answers a dashboard's requests about the Macs that this host manages, with the operations of this host's own window.
@MainActor
final class ManagedMacsRelay {
    /// How long the host keeps listing waiting Macs after a dashboard last asked. A dashboard asks again while its
    /// sheet is open, and cannot always say that it closed.
    static let discoveryLifetime = Duration.seconds(10)

    private let macs: PairedMacs
    private let canAddMacs: @MainActor () -> Bool
    private let session = UUID()
    private var revision = 0
    private var pairing: Task<Void, Never>?
    /// The last pairing that a dashboard started, and that dashboard. Only it reads, confirms, and cancels the pairing.
    private var pairingAttempt: (id: UUID, dashboard: HostPairing.ID)?
    /// An attempt that its dashboard cancelled before its request to start arrived on another connection.
    private var cancelledAttempt: UUID?
    private var pairedMac: ListedMac?
    private var pairingError: String?
    private var discovery: Task<Void, Never>?
    private var lastDiscoveryRequest = ContinuousClock.now

    init(macs: PairedMacs, canAddMacs: @escaping @MainActor () -> Bool) {
        self.macs = macs
        self.canAddMacs = canAddMacs
    }

    /// What this host tells `dashboard` about its Macs now.
    func report(for dashboard: HostPairing.ID) -> ManagedMacsReport {
        revision += 1
        // A pairing from this host's own Add Mac sheet, or from another dashboard, shows its code there.
        let attempt = pairingAttempt?.dashboard == dashboard ? pairingAttempt?.id : nil
        let isPairing = attempt != nil && pairing != nil
        return ManagedMacsReport(
            session: session, revision: revision,
            macs: macs.macs.map { mac in
                let settings = macs.settings(of: mac.id)
                return .init(
                    id: mac.id, name: mac.name, status: macs.status(of: mac.id), settings: settings?.report, readAt: settings?.readAt
                )
            },
            message: macs.message, canAddMacs: canAddMacs(), waitingMacs: macs.waitingMacs,
            discoveryMessage: macs.discoveryMessage, pairingAttempt: attempt,
            codeConfirmation: isPairing ? macs.codeConfirmation : nil, isPairing: isPairing,
            pairedMac: attempt != nil ? pairedMac : nil, pairingError: attempt != nil ? pairingError : nil
        )
    }

    /// - Parameter dashboard: The pairing of the dashboard that sent the request.
    /// - Returns: The reply, and whether a Mac saved an edited job limit, so that this host registers its runners
    ///   as it does after Apply in its own pane for the Mac.
    func answer(
        _ request: ManagedMacsRequest, from dashboard: HostPairing.ID
    ) async -> (reply: HostLinkReply, limitChanged: Bool) {
        var limitChanged = false
        do {
            switch request {
            case .read(let refreshing):
                if let refreshing { await macs.refresh(refreshing) }
            case .configurePool(let changes, let mac):
                try await relay(.configurePool(changes), to: mac)
                // The dashboard sends a limit only when it was edited. This host's last read of the Mac may be older
                // than the limit that the edit replaced, so it does not decide whether the limit changed.
                limitChanged = changes.maximumConcurrentJobs != nil
            case .saveStorage(let directory, let mac):
                try await relay(.saveStorage(directory: directory), to: mac)
            case .saveXcode(let developerDirectory, let mac):
                try await relay(.saveXcode(developerDirectory: developerDirectory), to: mac)
            case .setPaused(let isPaused, let mac):
                try await relay(.setPaused(isPaused), to: mac)
            case .restart(let mac):
                try await relay(.restart, to: mac)
            case .remove(let mac):
                await macs.remove(mac)
            case .discover:
                try requireCanAddMacs()
                lastDiscoveryRequest = .now
                discoverWhileAsked()
            case .pair(let waitingMac, let attempt):
                try requireCanAddMacs()
                guard attempt != cancelledAttempt else { break }
                // This host's own Add Mac sheet, or another dashboard, may be pairing.
                guard pairing == nil, !macs.isPairing else { throw PairedMacs.alreadyPairing }
                pairingAttempt = (attempt, dashboard)
                pairedMac = nil
                pairingError = nil
                pairing = Task {
                    do {
                        pairedMac = try await macs.pair(with: waitingMac)
                    } catch is CancellationError {
                    } catch {
                        pairingError = error.localizedDescription
                    }
                    pairing = nil
                }
            case .confirmCode(let attempt):
                guard pairingAttempt.map({ $0 == (attempt, dashboard) }) == true, pairing != nil else { break }
                macs.confirmCode()
            case .cancelPairing(let attempt):
                guard pairingAttempt.map({ $0 == (attempt, dashboard) }) == true else {
                    if pairingAttempt?.id != attempt { cancelledAttempt = attempt }
                    break
                }
                pairing?.cancel()
                await pairing?.value
            }
            return (.macs(report(for: dashboard)), limitChanged)
        } catch {
            return (.refused(error.localizedDescription), false)
        }
    }

    func shutDown() async {
        let tasks = [pairing, discovery]
        for task in tasks { task?.cancel() }
        for task in tasks { await task?.value }
    }

    /// Changes a Mac's settings. When the Mac does not confirm the change, the dashboard shows what this host's own
    /// pane for the Mac shows: the change may or may not have been applied.
    private func relay(_ request: HostSettingsRequest, to mac: HostPairing.ID) async throws {
        do {
            _ = try await macs.relay(request, to: mac)
        } catch {
            throw HostLinkError.refused(PairedMacSettings.changeFailure(error, on: macs.mac(mac)?.name ?? "The Mac"))
        }
    }

    private func requireCanAddMacs() throws {
        guard canAddMacs() else {
            throw HostLinkError.refused("\(HostPane.macName) is managed by another Mac, so it cannot add Macs.")
        }
    }

    /// Looks for waiting Macs for every dashboard that asks, alongside this host's own Add Mac sheet.
    private func discoverWhileAsked() {
        guard discovery == nil else { return }
        macs.discoverPairableMacs()
        discovery = Task {
            while lastDiscoveryRequest.duration(to: .now) < Self.discoveryLifetime {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
            discovery = nil
            macs.stopDiscoveringPairableMacs()
        }
    }
}
