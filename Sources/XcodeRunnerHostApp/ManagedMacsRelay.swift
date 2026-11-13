import Foundation

/// Reads or changes the Macs that a host manages, for a dashboard. The host answers with those Macs afterwards. The
/// dashboard has no pairing with them, so each request reaches them through the host's own pairing.
enum ManagedMacsRequest: Codable, Sendable {
    /// - Parameter refreshing: A Mac whose settings the host reads again first, because the dashboard shows its pane.
    case read(refreshing: HostPairing.ID?)
    case configurePool(PoolSettingsDraft.Changes, mac: HostPairing.ID)
    case saveStorage(directory: String, mac: HostPairing.ID)
    /// Ends the pairing between the host and a Mac.
    case remove(mac: HostPairing.ID)
    /// Lists the Macs that wait to pair with the host. The host keeps looking while dashboards keep asking.
    case discover
    /// Starts pairing the host with a waiting Mac. Later reads carry the code to confirm, and the result.
    ///
    /// - Parameter attempt: Names this pairing, so that the dashboard reads and cancels only its own.
    case pair(waitingMac: WaitingMac.ID, attempt: UUID)
    /// Confirms that the Mac being paired shows the same code as the report.
    case confirmCode
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

    let macs: [Mac]
    let message: String?
    /// Whether the host can pair with another Mac. A host that another Mac manages cannot.
    let canAddMacs: Bool
    let waitingMacs: [WaitingMac]
    let discoveryMessage: String?
    let codeConfirmation: PairedMacs.CodeConfirmation?
    /// The last pairing that a dashboard started.
    let pairingAttempt: UUID?
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
    private var pairing: Task<Void, Never>?
    private var pairingAttempt: UUID?
    private var pairedMac: ListedMac?
    private var pairingError: String?
    private var discovery: Task<Void, Never>?
    private var lastDiscoveryRequest = ContinuousClock.now

    init(macs: PairedMacs, canAddMacs: @escaping @MainActor () -> Bool) {
        self.macs = macs
        self.canAddMacs = canAddMacs
    }

    var report: ManagedMacsReport {
        ManagedMacsReport(
            macs: macs.macs.map { mac in
                let settings = macs.settings(of: mac.id)
                return .init(
                    id: mac.id, name: mac.name, status: macs.status(of: mac.id), settings: settings?.report, readAt: settings?.readAt
                )
            },
            message: macs.message, canAddMacs: canAddMacs(), waitingMacs: macs.waitingMacs,
            discoveryMessage: macs.discoveryMessage, codeConfirmation: macs.codeConfirmation,
            pairingAttempt: pairingAttempt, isPairing: pairing != nil, pairedMac: pairedMac, pairingError: pairingError
        )
    }

    /// - Returns: The reply, and whether a Mac saved a different job limit, so that this host registers its runners
    ///   as it does after Apply in its own pane for the Mac.
    func answer(_ request: ManagedMacsRequest) async -> (reply: HostLinkReply, limitChanged: Bool) {
        var limitChanged = false
        do {
            switch request {
            case .read(let refreshing):
                if let refreshing { await macs.refresh(refreshing) }
            case .configurePool(let changes, let mac):
                let previous = macs.settings(of: mac)?.report?.poolStatus?.configuration.maximumConcurrentJobs
                let saved = try await macs.relay(.configurePool(changes), to: mac)
                limitChanged = saved.poolStatus?.configuration.maximumConcurrentJobs != previous
            case .saveStorage(let directory, let mac):
                _ = try await macs.relay(.saveStorage(directory: directory), to: mac)
            case .remove(let mac):
                await macs.remove(mac)
            case .discover:
                try requireCanAddMacs()
                lastDiscoveryRequest = .now
                discoverWhileAsked()
            case .pair(let waitingMac, let attempt):
                try requireCanAddMacs()
                // This host's own Add Mac sheet, or another dashboard, may be pairing.
                guard pairing == nil, !macs.isPairing else { throw PairedMacs.alreadyPairing }
                pairingAttempt = attempt
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
            case .confirmCode:
                macs.confirmCode()
            case .cancelPairing(let attempt):
                guard attempt == pairingAttempt else { break }
                pairing?.cancel()
                await pairing?.value
            }
            return (.macs(report), limitChanged)
        } catch {
            return (.refused(error.localizedDescription), false)
        }
    }

    func shutDown() async {
        let tasks = [pairing, discovery]
        for task in tasks { task?.cancel() }
        for task in tasks { await task?.value }
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
