import AppKit
import Foundation
import Network
import Observation

/// A Mac that this Mac paired with: one that this host manages, or a host that this dashboard shows.
struct PairedMac: Codable, Equatable, Identifiable, Sendable {
    let pairing: HostPairing
    /// The Mac's identity across pairings.
    let hostID: UUID

    var id: HostPairing.ID { pairing.id }
    var name: String { pairing.name }
}

/// The settings that this Mac last read from a Mac paired with it, and the changes being edited for that Mac.
@MainActor @Observable
final class PairedMacSettings {
    private(set) var report: HostSettingsReport?
    /// When `report` was read.
    private(set) var readAt: Date?
    var poolDraft = PoolSettingsDraft()
    var storageDirectoryInput = ""
    fileprivate(set) var isSaving = false
    fileprivate(set) var isSavingStorage = false
    fileprivate(set) var saveError: String?
    fileprivate(set) var storageSaveError: String?
    /// The host's GitHub settings, which a dashboard reads with the settings above.
    private(set) var github: GitHubReport?
    /// The repository selection being edited.
    var selectedRepositoryIDs: Set<Int> = []
    fileprivate(set) var isChangingGitHub = false
    /// Why the host refused the last GitHub request, or why it did not confirm it.
    fileprivate(set) var githubError: String?
    /// Changes when a change to the Mac starts or ends, so that a read that overlaps a change does not show the
    /// settings from before it.
    fileprivate var changeCount = 0

    var canApplyPoolConfiguration: Bool { report?.canApplyPoolConfiguration == true && !isSaving }

    fileprivate var isChanging: Bool { isSaving || isSavingStorage || isChangingGitHub }

    /// Shows newly read GitHub settings, with the saved selection in a selection that was not edited.
    fileprivate func show(_ github: GitHubReport) {
        if selectedRepositoryIDs == self.github?.savedRepositoryIDs ?? [] { selectedRepositoryIDs = github.savedRepositoryIDs }
        self.github = github
    }

    /// Shows a newly read report, with its settings in the inputs that were not edited, as the Mac's own window does.
    fileprivate func show(_ report: HostSettingsReport) {
        if report.hasLoadedPoolStatus, report.poolError == nil { poolDraft.update(from: report.poolStatus?.configuration) }
        if storageDirectoryInput == self.report?.savedStorageDirectory?.path(percentEncoded: false) ?? "" {
            storageDirectoryInput = report.savedStorageDirectory?.path(percentEncoded: false) ?? ""
        }
        self.report = report
        readAt = .now
    }

    fileprivate func beginChange() { changeCount += 1 }
    fileprivate func endChange() { changeCount += 1 }
}

/// The runner folders of a Mac that this host manages, read and changed over the pairing connection.
struct PairedRunnerMac: RunnerMac {
    let id: HostPairing.ID
    let macs: PairedMacs

    func hostName() async throws -> String {
        guard case .hostName(let name) = try await macs.requestRunners(.hostName, from: id) else {
            throw HostLinkError.unexpectedReply
        }
        return name
    }

    func runners() async throws -> RunnerInventory {
        guard case .runners(let inventory) = try await macs.requestRunners(.inventory, from: id) else {
            throw HostLinkError.unexpectedReply
        }
        return inventory
    }

    func prepareArchive(_ download: GitHubRunnerDownload) async throws -> URL {
        guard case .archive(let archive) = try await macs.requestRunners(.prepareArchive(download), from: id) else {
            throw HostLinkError.unexpectedReply
        }
        return archive
    }

    func install(_ request: RunnerProvisioner.InstallationRequest) async throws {
        try await change(.install(request))
    }

    func markUnregistering(_ runner: String, from repositoryID: Int) async throws {
        try await change(.markUnregistering(runner: runner, repositoryID: repositoryID))
    }

    func markRemoved(_ runner: String) async throws { try await change(.markRemoved(runner: runner)) }

    private func change(_ request: RunnerRequest) async throws {
        guard case .completed = try await macs.requestRunners(request, from: id) else { throw HostLinkError.unexpectedReply }
    }
}

/// The Macs that this Mac paired with, and whether each one can be reached: the Macs that a host manages, or the
/// hosts that a dashboard shows.
@MainActor @Observable
final class PairedMacs {
    enum Status: Equatable {
        /// The Mac does not advertise this pairing's service on the local network.
        case notFound
        case checking
        case online
        /// The Mac no longer has this pairing.
        case rejected
        case unreachable(String)
    }

    /// A Mac that waits to pair.
    struct PairableMac: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    /// The code that the person compares with the one the Mac shows while pairing.
    struct CodeConfirmation: Equatable {
        let macName: String
        let code: String
        var isConfirmed = false
    }

    /// How often paired Macs are checked while they are found on the network.
    static let statusInterval = Duration.seconds(60)
    /// How often a Mac's settings are read while its pane is shown, so that its job counts stay current.
    static let settingsInterval = Duration.seconds(5)
    /// How long a Mac has to apply a change. A lower job limit removes idle Simulators before the Mac replies, and
    /// installing a runner registers it with GitHub.
    static let changeTimeout = Duration.seconds(300)
    /// How long a Mac has to download the official runner archive.
    static let downloadTimeout = Duration.seconds(900)

    private let store: any SecretStore
    private let name: String
    /// What this Mac does with the Macs it pairs with.
    let role: PairingRole
    private let browses: Bool
    private let openURL: @MainActor (URL) -> Bool
    private(set) var macs: [PairedMac] = []
    private(set) var statuses: [HostPairing.ID: Status] = [:]
    /// Kept while a Mac is not found, so that its pane can show when the settings were last read.
    private(set) var settings: [HostPairing.ID: PairedMacSettings] = [:]
    private(set) var pairableMacs: [PairableMac] = []
    private(set) var message: String?
    private(set) var discoveryMessage: String?
    private(set) var codeConfirmation: CodeConfirmation?
    private var confirmation: (id: UUID, continuation: CheckedContinuation<Void, any Error>)?
    private var endpoints: [HostPairing.ID: NWEndpoint] = [:]
    /// Every management service found, by pairing ID. A Mac advertises its new pairing before this host saves it.
    private var advertised: [HostPairing.ID: NWEndpoint] = [:]
    private var checking: Set<HostPairing.ID> = []
    private var browsing: Task<Void, Never>?
    private var pairableBrowsing: Task<Void, Never>?

    /// - Parameters:
    ///   - browses: Whether to find Macs with Bonjour. Tests pass endpoints instead.
    ///   - openURL: Opens GitHub's pages in this Mac's browser for a host that a dashboard shows.
    init(
        store: any SecretStore, name: String, role: PairingRole, browses: Bool = true,
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.store = store
        self.name = name
        self.role = role
        self.browses = browses
        self.openURL = openURL
        do {
            macs = try store.read().map { try JSONDecoder().decode([PairedMac].self, from: $0) } ?? []
            for mac in macs { settings[mac.id] = PairedMacSettings() }
        } catch {
            message = "Could not read the paired Macs: \(error.localizedDescription)"
        }
    }

    func mac(_ id: HostPairing.ID) -> PairedMac? { macs.first { $0.id == id } }
    func status(of id: HostPairing.ID) -> Status { statuses[id] ?? .notFound }

    /// Finds the paired Macs on the local network. Browsing waits for the first pairing, so a Mac that paired with
    /// no Macs does not ask for local network access.
    func start() {
        guard browses, browsing == nil, !macs.isEmpty else { return }
        browsing = Task {
            await withTaskGroup { group in
                group.addTask {
                    let browser = NetworkBrowser(for: .bonjour(HostLink.managementService, includeTxtRecord: true))
                    do {
                        try await browser.run { found in await self.managementServicesChanged(found) }
                    } catch is CancellationError {
                    } catch {
                        await self.showBrowsingFailure(error)
                    }
                }
                group.addTask {
                    while true {
                        do { try await Task.sleep(for: Self.statusInterval) } catch { return }
                        await self.checkFoundMacs()
                    }
                }
            }
        }
    }

    func shutDown() async {
        let tasks = [browsing, pairableBrowsing]
        browsing = nil
        pairableBrowsing = nil
        for task in tasks { task?.cancel() }
        for task in tasks { await task?.value }
    }

    /// Lists Macs that wait to pair with a Mac of this role until `stopDiscoveringPairableMacs()`.
    func discoverPairableMacs() {
        guard browses, pairableBrowsing == nil else { return }
        discoveryMessage = nil
        pairableBrowsing = Task {
            // The browser calls these handlers on the main actor, where they are created.
            let browser = NetworkBrowser(for: .bonjour(HostLink.pairingService, includeTxtRecord: true))
                .onStateUpdate { _, state in
                    guard case .waiting(let error) = state else { return }
                    self.showDiscoveryWaiting(error)
                }
            do {
                try await browser.run { found in self.pairableMacsChanged(found) }
            } catch is CancellationError {
            } catch {
                showDiscoveryWaiting(error)
            }
        }
    }

    func stopDiscoveringPairableMacs() {
        pairableBrowsing?.cancel()
        pairableBrowsing = nil
        pairableMacs = []
        discoveryMessage = nil
    }

    /// Pairs with the Mac at `endpoint`, replacing an earlier pairing with the same Mac.
    ///
    /// The pairing finishes after the person confirms `codeConfirmation` with `confirmCode()` and allows the
    /// pairing on the Mac.
    @discardableResult
    func pair(at endpoint: NWEndpoint) async throws -> PairedMac {
        defer { codeConfirmation = nil }
        let (pairing, hostID) = try await HostLink.requestPairing(
            at: endpoint, pairingID: UUID(), requesterName: name, role: role
        ) { macName, code in
            try await self.waitForConfirmation(of: code, from: macName)
        }
        let macName = pairing.name
        let mac = PairedMac(pairing: pairing, hostID: hostID)
        let replaced = macs.filter { $0.hostID == hostID }
        let next = macs.filter { $0.hostID != hostID } + [mac]
        do {
            try save(next)
        } catch {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                "\(macName) paired, but this Mac could not save the pairing: \(error.localizedDescription) \(endingInstruction(on: macName)), then pair again."
            ])
        }
        var keepsEarlierPairing = false
        for mac in replaced {
            // A Mac replaces its managing host by itself, and keeps every dashboard until told.
            if role == .dashboard {
                let reply: HostLinkReply? = if let endpoint = endpoints[mac.id] {
                    try? await HostLink.send(.unpair, to: endpoint, key: mac.pairing.symmetricKey, identity: mac.id.uuidString)
                } else {
                    nil
                }
                if case .unpaired? = reply {} else { keepsEarlierPairing = true }
            }
            forgetStatus(of: mac.id)
            settings[mac.id] = nil
        }
        macs = next
        settings[mac.id] = PairedMacSettings()
        message = keepsEarlierPairing
            ? "\(macName) could not be told to forget this Mac's earlier pairing. It lists this Mac twice under Dashboards until you remove one there."
            : nil
        if browsing == nil { start() } else { advertisedServicesChanged() }
        return mac
    }

    /// Confirms that the Mac being paired shows the same code as `codeConfirmation`.
    func confirmCode() {
        guard var codeConfirmation, !codeConfirmation.isConfirmed, let confirmation else { return }
        codeConfirmation.isConfirmed = true
        self.codeConfirmation = codeConfirmation
        self.confirmation = nil
        confirmation.continuation.resume()
    }

    private func waitForConfirmation(of code: String, from macName: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                confirmation = (id, continuation)
                codeConfirmation = CodeConfirmation(macName: macName, code: code)
            }
        } onCancel: {
            Task { @MainActor in
                guard let confirmation = self.confirmation, confirmation.id == id else { return }
                self.confirmation = nil
                confirmation.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Ends the pairing on both Macs. A Mac that cannot be told keeps accepting this Mac until the person ends the
    /// pairing there.
    func remove(_ id: HostPairing.ID) async {
        guard let mac = mac(id) else { return }
        var notice: String?
        if status(of: id) != .rejected {
            if let endpoint = endpoints[id] {
                do {
                    let reply = try await HostLink.send(.unpair, to: endpoint, key: mac.pairing.symmetricKey, identity: mac.id.uuidString)
                    if case .refused(let message) = reply { throw HostLinkError.refused(message) }
                    guard case .unpaired = reply else { throw HostLinkError.unexpectedReply }
                } catch {
                    notice = "\(mac.name) could not be told: \(error.localizedDescription) \(remainingAccess(on: mac.name))"
                }
            } else {
                notice = "\(mac.name) was not found on the local network. \(remainingAccess(on: mac.name))"
            }
        }
        let next = macs.filter { $0.id != id }
        do {
            try save(next)
        } catch {
            message = "Could not remove \(mac.name): \(error.localizedDescription)"
            return
        }
        macs = next
        forgetStatus(of: id)
        settings[id] = nil
        message = notice
        if macs.isEmpty {
            browsing?.cancel()
            browsing = nil
            advertised = [:]
        }
    }

    /// Reads the settings of the Mac at `endpoint`, which also shows whether it accepts this Mac. Browsing calls this
    /// when a paired Mac is found.
    func checkStatus(of id: HostPairing.ID, at endpoint: NWEndpoint) async {
        guard let mac = mac(id), !checking.contains(id) else { return }
        endpoints[id] = endpoint
        checking.insert(id)
        defer { checking.remove(id) }
        if statuses[id] == nil || statuses[id] == .notFound { statuses[id] = .checking }
        let changeCount = settings[id]?.changeCount
        let status: Status
        var report: HostSettingsReport?
        var github: GitHubReport?
        do {
            report = try await requestSettings(.read, from: mac, at: endpoint)
            // A dashboard shows the host's GitHub settings too. A managing host has its own.
            if role == .dashboard { github = try await requestGitHub(.read, from: mac, at: endpoint) }
            status = .online
        } catch HostLinkError.rejected {
            status = .rejected
        } catch {
            status = .unreachable(error.localizedDescription)
        }
        // A closed pane cancels its read, which says nothing about the Mac. The Mac may also have been removed or lost
        // from the network while the request waited.
        guard !Task.isCancelled, self.mac(id) != nil, endpoints[id] == endpoint else { return }
        statuses[id] = status
        if let report, let settings = settings[id], settings.changeCount == changeCount, !settings.isChanging {
            settings.show(report)
            if let github { settings.show(github) }
        }
    }

    /// Reads a Mac's settings every `settingsInterval` until the task is cancelled.
    func watchSettings(of id: HostPairing.ID) async {
        while true {
            if let endpoint = endpoints[id] { await checkStatus(of: id, at: endpoint) }
            do { try await Task.sleep(for: Self.settingsInterval) } catch { return }
        }
    }

    /// Applies the job limit and Simulator retention edited for a Mac, after the checks that the Mac's own window
    /// makes.
    ///
    /// - Returns: Whether the Mac saved a different job limit, so that its runner registrations need updating.
    @discardableResult
    func applyPoolConfiguration(of id: HostPairing.ID) async -> Bool {
        guard let mac = mac(id), let settings = settings[id], let report = settings.report, settings.canApplyPoolConfiguration
        else { return false }
        let changes: PoolSettingsDraft.Changes
        do {
            changes = try settings.poolDraft.changes(isNewPool: report.isNewPool)
        } catch {
            settings.saveError = error.localizedDescription
            return false
        }
        let previousCapacity = report.poolStatus?.configuration.maximumConcurrentJobs
        settings.isSaving = true
        settings.beginChange()
        defer {
            settings.isSaving = false
            settings.endChange()
        }
        do {
            let report = try await requestSettings(.configurePool(changes), from: mac)
            settings.saveError = nil
            settings.show(report)
            guard let saved = report.poolStatus?.configuration else { return false }
            settings.poolDraft.reset(to: saved)
            return saved.maximumConcurrentJobs != previousCapacity
        } catch {
            settings.saveError = Self.changeFailure(error, on: mac)
            return false
        }
    }

    func saveStorageDirectory(of id: HostPairing.ID) async {
        guard let mac = mac(id), let settings = settings[id], settings.report?.canEditStorage == true, !settings.isSavingStorage
        else { return }
        settings.isSavingStorage = true
        settings.beginChange()
        defer {
            settings.isSavingStorage = false
            settings.endChange()
        }
        do {
            let report = try await requestSettings(.saveStorage(directory: settings.storageDirectoryInput), from: mac)
            settings.storageSaveError = nil
            settings.show(report)
            settings.storageDirectoryInput = report.savedStorageDirectory?.path(percentEncoded: false) ?? ""
        } catch {
            settings.storageSaveError = Self.changeFailure(error, on: mac)
        }
    }

    private func requestSettings(
        _ request: HostSettingsRequest, from mac: PairedMac, at endpoint: NWEndpoint? = nil
    ) async throws -> HostSettingsReport {
        guard let endpoint = endpoint ?? endpoints[mac.id] else {
            throw HostLinkError.unreachable("\(mac.name) was not found on the local network.")
        }
        let timeout = if case .read = request { HostLink.requestTimeout } else { Self.changeTimeout }
        let reply = try await HostLink.send(
            .settings(request), to: endpoint, key: mac.pairing.symmetricKey, identity: mac.id.uuidString, timeout: timeout
        )
        switch reply {
        case .settings(let report): return report
        case .refused(let message): throw HostLinkError.refused(message)
        default: throw HostLinkError.unexpectedReply
        }
    }

    /// Starts the host's GitHub sign-in and opens GitHub's page for its code in this Mac's browser.
    func signIn(to id: HostPairing.ID) async {
        guard let code = await changeGitHub(.signIn, of: id)?.signInCode else { return }
        if !openURL(code.verificationURI) { settings[id]?.githubError = "Could not open your browser." }
    }

    func cancelSignIn(to id: HostPairing.ID) async { await changeGitHub(.cancelSignIn, of: id) }
    func signOut(of id: HostPairing.ID) async { await changeGitHub(.signOut, of: id) }
    func reloadRepositories(of id: HostPairing.ID) async { await changeGitHub(.reloadRepositories, of: id) }

    /// Saves the repository selection edited for a host. The host then registers and removes runners.
    func applyRepositorySelection(of id: HostPairing.ID) async {
        guard let settings = settings[id] else { return }
        guard let saved = await changeGitHub(.applySelection(settings.selectedRepositoryIDs), of: id) else { return }
        settings.selectedRepositoryIDs = saved.savedRepositoryIDs
    }

    /// Opens the page that installs the host's GitHub App on repositories, in this Mac's browser.
    func addRepositories(to id: HostPairing.ID) {
        guard let settings = settings[id], let url = settings.github?.installationURL else { return }
        settings.githubError = openURL(url) ? nil : "Could not open your browser."
    }

    /// Sends a change to a host's GitHub settings and shows the settings that the host answers with.
    @discardableResult
    private func changeGitHub(_ request: GitHubRequest, of id: HostPairing.ID) async -> GitHubReport? {
        guard let mac = mac(id), let settings = settings[id], !settings.isChangingGitHub else { return nil }
        settings.isChangingGitHub = true
        settings.beginChange()
        defer {
            settings.isChangingGitHub = false
            settings.endChange()
        }
        do {
            let report = try await requestGitHub(request, from: mac)
            settings.githubError = nil
            settings.show(report)
            return report
        } catch {
            settings.githubError = Self.changeFailure(error, on: mac)
            return nil
        }
    }

    private func requestGitHub(
        _ request: GitHubRequest, from mac: PairedMac, at endpoint: NWEndpoint? = nil
    ) async throws -> GitHubReport {
        guard let endpoint = endpoint ?? endpoints[mac.id] else {
            throw HostLinkError.unreachable("\(mac.name) was not found on the local network.")
        }
        let timeout = if case .read = request { HostLink.requestTimeout } else { Self.changeTimeout }
        let reply = try await HostLink.send(
            .github(request), to: endpoint, key: mac.pairing.symmetricKey, identity: mac.id.uuidString, timeout: timeout
        )
        switch reply {
        case .github(let report): return report
        case .refused(let message): throw HostLinkError.refused(message)
        default: throw HostLinkError.unexpectedReply
        }
    }

    /// Reads a Mac's settings now, without showing them in its pane.
    func readSettings(of id: HostPairing.ID) async throws -> HostSettingsReport {
        guard let mac = mac(id) else { throw HostLinkError.unreachable("The Mac is no longer paired.") }
        return try await requestSettings(.read, from: mac)
    }

    /// Sends a request about a Mac's runner folders, and throws the Mac's refusal.
    func requestRunners(_ request: RunnerRequest, from id: HostPairing.ID) async throws -> HostLinkReply {
        guard let mac = mac(id) else { throw HostLinkError.unreachable("The Mac is no longer paired.") }
        guard let endpoint = endpoints[mac.id] else {
            throw HostLinkError.unreachable("\(mac.name) was not found on the local network.")
        }
        let timeout = switch request {
        case .prepareArchive: Self.downloadTimeout
        case .install: Self.changeTimeout
        default: HostLink.requestTimeout
        }
        let reply = try await HostLink.send(
            .runners(request), to: endpoint, key: mac.pairing.symmetricKey, identity: mac.id.uuidString, timeout: timeout
        )
        if case .refused(let message) = reply { throw HostLinkError.refused(message) }
        return reply
    }

    /// The Mac's own message when it refused the change. Otherwise the change may or may not have been applied.
    private static func changeFailure(_ error: any Error, on mac: PairedMac) -> String {
        if case .refused(let message) = error as? HostLinkError { return message }
        return "\(mac.name) did not confirm the change: \(error.localizedDescription)"
    }

    /// How the person ends this pairing on the other Mac.
    private func endingInstruction(on macName: String) -> String {
        switch role {
        case .manager: "Choose Stop Management on \(macName)"
        case .dashboard: "Remove this Mac under Dashboards on \(macName)"
        }
    }

    private func remainingAccess(on macName: String) -> String {
        switch role {
        case .manager: "It accepts this Mac as its managing host until you choose Stop Management on it."
        case .dashboard: "It accepts this Mac as a dashboard until you remove this Mac under Dashboards on it."
        }
    }

    private func save(_ macs: [PairedMac]) throws {
        if macs.isEmpty { try store.remove() } else { try store.write(JSONEncoder().encode(macs)) }
    }

    private func forgetStatus(of id: HostPairing.ID) {
        statuses[id] = nil
        endpoints[id] = nil
    }

    private func managementServicesChanged(_ found: [Bonjour.Endpoint]) {
        advertised = [:]
        for service in found {
            guard let value = service.txtRecord[HostLink.pairingKeyName], let id = UUID(uuidString: value) else { continue }
            advertised[id] = service.nwEndpoint
        }
        advertisedServicesChanged()
    }

    /// Checks the paired Macs whose service appeared or moved, and forgets the status of the ones no longer found.
    private func advertisedServicesChanged() {
        let current = advertised.filter { mac($0.key) != nil }
        let previous = endpoints
        for id in previous.keys where current[id] == nil { forgetStatus(of: id) }
        for (id, endpoint) in current where previous[id] != endpoint {
            endpoints[id] = endpoint
            Task { await checkStatus(of: id, at: endpoint) }
        }
    }

    private func checkFoundMacs() async {
        await withTaskGroup { group in
            for (id, endpoint) in endpoints {
                group.addTask { await self.checkStatus(of: id, at: endpoint) }
            }
        }
    }

    private func pairableMacsChanged(_ found: [Bonjour.Endpoint]) {
        guard pairableBrowsing != nil else { return }
        discoveryMessage = nil
        // A Mac waits for one role, and refuses a request for the other.
        pairableMacs = found.filter { $0.txtRecord[HostLink.roleKeyName] == role.rawValue }.map { PairableMac(id: $0.id, name: $0.name, endpoint: $0.nwEndpoint) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func showDiscoveryWaiting(_ error: any Error) {
        guard pairableBrowsing != nil else { return }
        if case .dns(let code) = error as? NWError, code == kDNSServiceErr_PolicyDenied {
            discoveryMessage = "Allow XcodeHomeRunner in System Settings > Privacy & Security > Local Network to find other Macs."
        } else {
            discoveryMessage = "Could not look for Macs on the local network: \(error.localizedDescription)"
        }
    }

    private func showBrowsingFailure(_ error: any Error) {
        browsing = nil
        advertised = [:]
        message = "Could not look for paired Macs on the local network: \(error.localizedDescription)"
    }
}
