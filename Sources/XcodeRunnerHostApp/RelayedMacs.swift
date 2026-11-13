import Foundation
import Observation

/// The Macs that a host manages, as a dashboard lists and changes them through that host. The dashboard has no
/// pairing with these Macs.
@MainActor @Observable
final class RelayedMacs: MacList {
    /// How often the host is asked while it lists waiting Macs or pairs with one.
    static let pairingInterval = Duration.milliseconds(500)

    // The hosts own this list and remove it with its host.
    private unowned let hosts: PairedMacs
    private let host: HostPairing.ID
    private var report: ManagedMacsReport?
    private var settings: [HostPairing.ID: PairedMacSettings] = [:]
    /// Why the host refused the last change, or why it did not confirm it.
    private var requestError: String?
    private var discoveryError: String?
    private var discovering: Task<Void, Never>?
    /// The pairing that this dashboard started on the host. The host pairs for one dashboard at a time.
    private var pairingAttempt: UUID?
    /// The host's session and revision of the report that is shown.
    private var shown: (session: UUID, revision: Int)?

    init(hosts: PairedMacs, host: HostPairing.ID) {
        self.hosts = hosts
        self.host = host
    }

    /// The host manages these Macs, so their panes are the host's panes for them.
    let role = PairingRole.manager
    var pairedWith: MacReference { MacReference(name: hostName) }
    var listedMacs: [ListedMac] { report?.macs.map { ListedMac(id: $0.id, name: $0.name) } ?? [] }
    var message: String? { requestError ?? report?.message }
    /// Whether the host can pair with another Mac. A host that another Mac manages cannot.
    var canAddMacs: Bool { report?.canAddMacs == true }
    var waitingMacs: [WaitingMac] { report?.waitingMacs ?? [] }
    var discoveryMessage: String? { discoveryError ?? report?.discoveryMessage }
    /// The code of the pairing that this dashboard started. Another dashboard's pairing shows its code there.
    var codeConfirmation: PairedMacs.CodeConfirmation? {
        guard let pairingAttempt, report?.pairingAttempt == pairingAttempt else { return nil }
        return report?.codeConfirmation
    }

    func status(of id: HostPairing.ID) -> PairedMacs.Status { report?.macs.first { $0.id == id }?.status ?? .notFound }
    func settings(of id: HostPairing.ID) -> PairedMacSettings? { settings[id] }

    /// Shows what the host answered, unless a report that the host made later is already shown. Answers can arrive in
    /// another order, and the earlier one can list a Mac that was removed since, or settings from before a change.
    func show(_ report: ManagedMacsReport) {
        if let shown, shown.session == report.session, report.revision <= shown.revision { return }
        shown = (report.session, report.revision)
        var next: [HostPairing.ID: PairedMacSettings] = [:]
        for mac in report.macs {
            let settings = settings[mac.id] ?? PairedMacSettings()
            next[mac.id] = settings
            // A change that is still being sent shows the settings that it saved.
            if let read = mac.settings, let readAt = mac.readAt, !settings.isChanging { settings.show(read, readAt: readAt) }
        }
        settings = next
        self.report = report
    }

    func watchSettings(of id: HostPairing.ID) async {
        while true {
            // The host's own panes show whether it answers.
            _ = try? await request(.read(refreshing: id))
            do { try await Task.sleep(for: PairedMacs.settingsInterval) } catch { return }
        }
    }

    @discardableResult
    func applyPoolConfiguration(of id: HostPairing.ID) async -> Bool {
        guard let settings = settings[id], let mac = listedMacs.first(where: { $0.id == id }) else { return false }
        return await settings.applyPoolConfiguration(on: mac.name) { changes in
            try await self.change(.configurePool(changes, mac: id), of: id)
        }
    }

    func saveStorageDirectory(of id: HostPairing.ID) async {
        guard let settings = settings[id], let mac = listedMacs.first(where: { $0.id == id }) else { return }
        await settings.saveStorageDirectory(on: mac.name) { directory in
            try await self.change(.saveStorage(directory: directory, mac: id), of: id)
        }
    }

    func saveXcodeSelection(of id: HostPairing.ID) async {
        guard let settings = settings[id], let mac = listedMacs.first(where: { $0.id == id }) else { return }
        await settings.saveXcodeSelection(on: mac.name) { developerDirectory in
            try await self.change(.saveXcode(developerDirectory: developerDirectory, mac: id), of: id)
        }
    }

    @discardableResult
    func saveRunnerLabels(of id: HostPairing.ID) async -> Bool {
        guard let settings = settings[id], let mac = listedMacs.first(where: { $0.id == id }) else { return false }
        return await settings.saveRunnerLabels(on: mac.name) { labels in
            try await self.change(.saveRunnerLabels(labels, mac: id), of: id)
        }
    }

    func setPaused(_ isPaused: Bool, of id: HostPairing.ID) async {
        guard let settings = settings[id], let mac = listedMacs.first(where: { $0.id == id }) else { return }
        await settings.setPaused(isPaused, on: mac.name) { isPaused in
            try await self.change(.setPaused(isPaused, mac: id), of: id)
        }
    }

    func restart(_ id: HostPairing.ID) async {
        guard let settings = settings[id], let mac = listedMacs.first(where: { $0.id == id }) else { return }
        await settings.restart(on: mac.name) { try await self.change(.restart(mac: id), of: id) }
    }

    func remove(_ id: HostPairing.ID) async { await send(.remove(mac: id)) }

    func discoverPairableMacs() {
        guard discovering == nil else { return }
        discoveryError = nil
        discovering = Task {
            // The host lists the Macs that it finds, and stops looking once it is no longer asked.
            while true {
                do {
                    try await request(.discover)
                    discoveryError = nil
                } catch is CancellationError {
                    return
                } catch {
                    discoveryError = PairedMacSettings.changeFailure(error, on: hostName ?? "The host")
                }
                do { try await Task.sleep(for: Self.pairingInterval) } catch { return }
            }
        }
    }

    func stopDiscoveringPairableMacs() {
        discovering?.cancel()
        discovering = nil
        discoveryError = nil
    }

    /// Has the host pair with a waiting Mac. The host pairs while the person confirms the code on the dashboard and
    /// allows the pairing on the Mac.
    func pair(with id: WaitingMac.ID) async throws -> ListedMac {
        let attempt = UUID()
        pairingAttempt = attempt
        defer { if pairingAttempt == attempt { pairingAttempt = nil } }
        do {
            try await request(.pair(waitingMac: id, attempt: attempt))
            while true {
                try await Task.sleep(for: Self.pairingInterval)
                let report = try await request(.read(refreshing: nil))
                // Another dashboard's pairing replaces this one's result once this one ended.
                guard report.pairingAttempt == attempt else { throw HostLinkError.unexpectedReply }
                if let mac = report.pairedMac { return mac }
                if let error = report.pairingError { throw HostLinkError.refused(error) }
                guard report.isPairing else { throw HostLinkError.unexpectedReply }
            }
        } catch {
            // The host may still be pairing for this attempt, with no dashboard left to show the code: this sheet was
            // cancelled, or a request to the host failed. The task that ends here may be cancelled, so another one
            // tells the host.
            Task { _ = try? await self.request(.cancelPairing(attempt: attempt)) }
            throw error
        }
    }

    func confirmCode() {
        guard let pairingAttempt else { return }
        Task { await send(.confirmCode(attempt: pairingAttempt)) }
    }

    private var hostName: String? { hosts.mac(host)?.name }

    /// Sends a request and shows what the host answered.
    @discardableResult
    private func request(_ request: ManagedMacsRequest) async throws -> ManagedMacsReport {
        let report = try await hosts.requestManagedMacs(request, from: host)
        show(report)
        return report
    }

    /// Sends a change and shows what the host answered, or why it did not confirm the change.
    private func send(_ change: ManagedMacsRequest) async {
        do {
            try await request(change)
            requestError = nil
        } catch {
            requestError = PairedMacSettings.changeFailure(error, on: hostName ?? "The host")
        }
    }

    /// Sends a change to one Mac's settings and returns the settings that the Mac answered the host with.
    private func change(_ change: ManagedMacsRequest, of id: HostPairing.ID) async throws -> HostSettingsReport {
        guard let settings = try await request(change).macs.first(where: { $0.id == id })?.settings else {
            throw HostLinkError.unexpectedReply
        }
        return settings
    }
}
