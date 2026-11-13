import Foundation
import Observation

/// The Macs that a host manages, as a dashboard lists and changes them through that host. The dashboard has no
/// pairing with these Macs.
@MainActor @Observable
final class RelayedMacs: MacList {
    /// How often the host is read while it lists waiting Macs or pairs with one.
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
    var codeConfirmation: PairedMacs.CodeConfirmation? { report?.codeConfirmation }

    func status(of id: HostPairing.ID) -> PairedMacs.Status { report?.macs.first { $0.id == id }?.status ?? .notFound }
    func settings(of id: HostPairing.ID) -> PairedMacSettings? { settings[id] }

    /// Shows what the host answered.
    ///
    /// - Parameter changeCounts: Each Mac's change count before the request, so that a read that overlaps a change
    ///   does not show the settings from before it.
    func show(_ report: ManagedMacsReport, readSince changeCounts: [HostPairing.ID: Int]? = nil) {
        var next: [HostPairing.ID: PairedMacSettings] = [:]
        for mac in report.macs {
            let settings = settings[mac.id] ?? PairedMacSettings()
            next[mac.id] = settings
            guard let read = mac.settings, let readAt = mac.readAt, !settings.isChanging else { continue }
            if let changeCounts, changeCounts[mac.id] ?? 0 != settings.changeCount { continue }
            settings.show(read, readAt: readAt)
        }
        settings = next
        self.report = report
    }

    func watchSettings(of id: HostPairing.ID) async {
        while true {
            await read(refreshing: id)
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

    func remove(_ id: HostPairing.ID) async { await send(.remove(mac: id)) }

    func discoverPairableMacs() {
        guard discovering == nil else { return }
        discoveryError = nil
        discovering = Task {
            do {
                show(try await hosts.requestManagedMacs(.discover, from: host))
            } catch {
                discoveryError = PairedMacSettings.changeFailure(error, on: hostName ?? "The host")
                return
            }
            // The host lists the Macs that it finds, and stops looking once these reads stop.
            while true {
                do { try await Task.sleep(for: Self.pairingInterval) } catch { return }
                await read()
            }
        }
    }

    func stopDiscoveringPairableMacs() {
        discovering?.cancel()
        discovering = nil
        discoveryError = nil
        Task { await send(.stopDiscovering) }
    }

    /// Has the host pair with a waiting Mac. The host pairs while the person confirms the code on the dashboard and
    /// allows the pairing on the Mac.
    func pair(with id: WaitingMac.ID) async throws -> ListedMac {
        show(try await hosts.requestManagedMacs(.pair(waitingMac: id), from: host))
        return try await withTaskCancellationHandler {
            while true {
                try await Task.sleep(for: Self.pairingInterval)
                let report = try await hosts.requestManagedMacs(.read(refreshing: nil), from: host)
                show(report)
                if let mac = report.pairedMac { return mac }
                if let error = report.pairingError { throw HostLinkError.refused(error) }
                guard report.isPairing else { throw HostLinkError.unexpectedReply }
            }
        } onCancel: {
            Task { @MainActor in await self.send(.cancelPairing) }
        }
    }

    func confirmCode() {
        Task { await send(.confirmCode) }
    }

    private var hostName: String? { hosts.mac(host)?.name }

    private func read(refreshing id: HostPairing.ID? = nil) async {
        let changeCounts = settings.mapValues(\.changeCount)
        // The host's own panes show whether it answers.
        guard let report = try? await hosts.requestManagedMacs(.read(refreshing: id), from: host) else { return }
        show(report, readSince: changeCounts)
    }

    /// Sends a change and shows what the host answered, or why it did not confirm the change.
    private func send(_ request: ManagedMacsRequest) async {
        do {
            show(try await hosts.requestManagedMacs(request, from: host))
            requestError = nil
        } catch {
            requestError = PairedMacSettings.changeFailure(error, on: hostName ?? "The host")
        }
    }

    /// Sends a change to one Mac's settings and returns the settings that the Mac answered the host with.
    private func change(_ request: ManagedMacsRequest, of id: HostPairing.ID) async throws -> HostSettingsReport {
        let report = try await hosts.requestManagedMacs(request, from: host)
        show(report)
        guard let settings = report.macs.first(where: { $0.id == id })?.settings else { throw HostLinkError.unexpectedReply }
        return settings
    }
}
