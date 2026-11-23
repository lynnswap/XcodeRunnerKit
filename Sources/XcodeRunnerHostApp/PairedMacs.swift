import AppKit
import Foundation
import XcodeRunnerHostSupport
import Network
import Observation

/// A Mac that this Mac paired with: one that this host manages, or a host that this dashboard shows.
struct PairedMac: Codable, Equatable, Identifiable, Sendable {
    let pairing: HostPairing
    /// The Mac's identity across pairings.
    let hostID: UUID

    var id: HostPairing.ID { pairing.id }
    var name: String { pairing.name }
    var listed: ListedMac { ListedMac(id: id, name: name) }
}

/// The settings that this Mac last read from a Mac paired with it, and the changes being edited for that Mac.
@MainActor @Observable
final class PairedMacSettings {
    private(set) var resourceHistory = RunnerMetricHistory()
    private(set) var report: HostSettingsReport?
    /// When `report` was read.
    private(set) var readAt: Date?
    var poolDraft = PoolSettingsDraft()
    let hostDraft = HostSettingsDraft()
    let runnerSave = SettingsSave<RunnerSetting>()
    var jobOptionsSyncError: String?
    var storageDirectoryInput = ""
    private(set) var isSaving = false
    private(set) var isSavingStorage = false
    private(set) var saveError: String?
    private(set) var storageSaveError: String?
    /// The selected Xcode's `Contents/Developer` directory, or an empty string for the system selection.
    var xcodeSelectionInput = ""
    private(set) var isSavingXcode = false
    private(set) var xcodeSaveError: String?
    /// The path of the build service's executable, or an empty string to save none.
    var buildServiceInput = ""
    private(set) var isSavingBuildService = false
    private(set) var isSavingJobOptions = false
    private(set) var buildServiceSaveError: String?
    /// The labels being edited for the Mac's runners, separated by commas.
    var runnerLabelsInput = ""
    private(set) var isSavingRunnerLabels = false
    private(set) var runnerLabelsError: String?
    private(set) var isChangingPause = false
    /// Why the Mac refused to pause or resume, or why it did not confirm the change.
    private(set) var pauseError: String?
    private(set) var isRestarting = false
    /// Why the Mac refused to restart, or why it did not confirm that it restarts.
    private(set) var restartError: String?
    /// The host's GitHub settings, which a dashboard reads with the settings above.
    private(set) var github: GitHubReport?
    /// The repository selection being edited.
    var selectedRepositoryIDs: Set<Int> = []
    fileprivate(set) var isChangingGitHub = false
    /// Why the host refused the last GitHub request, or why it did not confirm it.
    fileprivate(set) var githubError: String?
    /// Changes when a change to the Mac starts or ends, so that a read that overlaps a change does not show the
    /// settings from before it.
    private(set) var changeCount = 0

    var canApplyPoolConfiguration: Bool { report?.canApplyPoolConfiguration == true && !isSaving }

    var isChanging: Bool {
        isSaving || isSavingStorage || isSavingXcode || isSavingBuildService || isSavingJobOptions || isSavingRunnerLabels || isChangingPause || isRestarting
            || isChangingGitHub
    }

    /// Shows newly read GitHub settings, with the saved selection in a selection that was not edited.
    fileprivate func show(_ github: GitHubReport) {
        if selectedRepositoryIDs == self.github?.savedRepositoryIDs ?? [] { selectedRepositoryIDs = github.savedRepositoryIDs }
        self.github = github
    }

    /// Shows a newly read report, with its settings in the inputs that were not edited, as the Mac's own window does.
    ///
    /// - Parameter readAt: When the report was read, if another Mac read it.
    func show(_ report: HostSettingsReport, readAt: Date = .now) {
        if let sample = report.resourceSample { resourceHistory.append(sample) }
        if report.hasLoadedPoolStatus, report.poolError == nil { poolDraft.update(from: report.poolStatus?.configuration) }
        if storageDirectoryInput == self.report?.savedStorageDirectory?.path(percentEncoded: false) ?? "" {
            storageDirectoryInput = report.savedStorageDirectory?.path(percentEncoded: false) ?? ""
        }
        if xcodeSelectionInput == self.report?.savedDeveloperDirectory?.path(percentEncoded: false) ?? "" {
            xcodeSelectionInput = report.savedDeveloperDirectory?.path(percentEncoded: false) ?? ""
        }
        if buildServiceInput == self.report?.savedBuildService?.path(percentEncoded: false) ?? "" {
            buildServiceInput = report.savedBuildService?.path(percentEncoded: false) ?? ""
        }
        if runnerLabelsInput == RunnerLabels.text(self.report?.runnerLabels ?? []) {
            runnerLabelsInput = RunnerLabels.text(report.runnerLabels)
        }
        self.report = report
        self.readAt = readAt
    }

    fileprivate func beginChange() { changeCount += 1 }
    fileprivate func endChange() { changeCount += 1 }

    /// Applies the edited job limit and Simulator retention, after the checks that the Mac's own window makes.
    ///
    /// - Parameter send: Sends the changes to the Mac named `macName` and returns the settings it answers with.
    /// - Returns: Whether the Mac saved a different job limit, so that its runner registrations need updating.
    func applyPoolConfiguration(
        on macName: String, send: (PoolSettingsDraft.Changes) async throws -> HostSettingsReport
    ) async -> Bool {
        guard let report, canApplyPoolConfiguration else { return false }
        let changes: PoolSettingsDraft.Changes
        do {
            changes = try poolDraft.changes(isNewPool: report.isNewPool)
        } catch {
            saveError = error.localizedDescription
            return false
        }
        let previousCapacity = report.poolStatus?.configuration.maximumConcurrentJobs
        isSaving = true
        beginChange()
        defer {
            isSaving = false
            endChange()
        }
        do {
            let report = try await send(changes)
            saveError = nil
            show(report)
            guard let saved = report.poolStatus?.configuration else { return false }
            poolDraft.reset(to: saved)
            return saved.maximumConcurrentJobs != previousCapacity
        } catch {
            saveError = Self.changeFailure(error, on: macName)
            return false
        }
    }

    /// Saves the edited storage folder.
    ///
    /// - Parameter send: Sends the folder to the Mac named `macName` and returns the settings it answers with.
    func saveStorageDirectory(on macName: String, send: (String) async throws -> HostSettingsReport) async {
        guard report?.canEditStorage == true, !isSavingStorage else { return }
        isSavingStorage = true
        beginChange()
        defer {
            isSavingStorage = false
            endChange()
        }
        do {
            let report = try await send(storageDirectoryInput)
            storageSaveError = nil
            show(report)
            storageDirectoryInput = report.savedStorageDirectory?.path(percentEncoded: false) ?? ""
        } catch {
            storageSaveError = Self.changeFailure(error, on: macName)
        }
    }

    /// Saves the selected Xcode for the Mac's jobs.
    ///
    /// - Parameter send: Sends the selection to the Mac named `macName`, as a `Contents/Developer` directory or `nil`
    ///   for the system selection, and returns the settings it answers with.
    func saveXcodeSelection(on macName: String, send: (String?) async throws -> HostSettingsReport) async {
        guard report != nil, !isSavingXcode else { return }
        isSavingXcode = true
        beginChange()
        defer {
            isSavingXcode = false
            endChange()
        }
        do {
            let report = try await send(xcodeSelectionInput.isEmpty ? nil : xcodeSelectionInput)
            xcodeSaveError = nil
            show(report)
            xcodeSelectionInput = report.savedDeveloperDirectory?.path(percentEncoded: false) ?? ""
        } catch {
            xcodeSaveError = Self.changeFailure(error, on: macName)
        }
    }

    /// Saves the entered build service for the Mac's jobs.
    ///
    /// - Parameter send: Sends the path of the service's executable to the Mac named `macName`, or `nil` to save
    ///   none, and returns the settings it answers with.
    func saveBuildService(on macName: String, send: (String?) async throws -> HostSettingsReport) async {
        guard report != nil, !isSavingBuildService else { return }
        isSavingBuildService = true
        beginChange()
        defer {
            isSavingBuildService = false
            endChange()
        }
        do {
            let report = try await send(buildServiceInput.isEmpty ? nil : buildServiceInput)
            buildServiceSaveError = nil
            show(report)
            buildServiceInput = report.savedBuildService?.path(percentEncoded: false) ?? ""
        } catch {
            buildServiceSaveError = Self.changeFailure(error, on: macName)
        }
    }

    func saveJobOptions(send: () async throws -> HostSettingsReport) async throws {
        isSavingJobOptions = true
        beginChange()
        defer {
            isSavingJobOptions = false
            endChange()
        }
        show(try await send())
    }

    /// Saves the edited labels for the Mac's runners.
    ///
    /// - Parameter send: Sends the labels to the Mac named `macName` and returns the settings it answers with.
    /// - Returns: Whether the Mac saved a different list, so that its runners need updating.
    func saveRunnerLabels(on macName: String, send: ([String]) async throws -> HostSettingsReport) async -> Bool {
        guard let previous = report?.runnerLabels, !isSavingRunnerLabels else { return false }
        isSavingRunnerLabels = true
        beginChange()
        defer {
            isSavingRunnerLabels = false
            endChange()
        }
        do {
            let report = try await send(RunnerLabels.parse(runnerLabelsInput))
            runnerLabelsError = nil
            show(report)
            runnerLabelsInput = RunnerLabels.text(report.runnerLabels)
            return report.runnerLabels != previous
        } catch {
            runnerLabelsError = Self.changeFailure(error, on: macName)
            return false
        }
    }

    /// Pauses or resumes the Mac.
    ///
    /// - Parameter send: Sends the change to the Mac named `macName` and returns the settings it answers with.
    func setPaused(_ isPaused: Bool, on macName: String, send: (Bool) async throws -> HostSettingsReport) async {
        guard report != nil, !isChangingPause else { return }
        isChangingPause = true
        beginChange()
        defer {
            isChangingPause = false
            endChange()
        }
        do {
            show(try await send(isPaused))
            pauseError = nil
        } catch {
            pauseError = Self.changeFailure(error, on: macName)
        }
    }

    /// Restarts the Mac's host, which applies its saved storage folder.
    ///
    /// - Parameter send: Asks the Mac named `macName` to restart and returns the settings it answers with first.
    func restart(on macName: String, send: () async throws -> HostSettingsReport) async {
        guard report?.canRestart == true, !isRestarting, !isSaving, !isSavingStorage else { return }
        isRestarting = true
        beginChange()
        defer {
            isRestarting = false
            endChange()
        }
        do {
            show(try await send())
            restartError = nil
        } catch {
            restartError = Self.changeFailure(error, on: macName)
        }
    }

    /// The Mac's own message when it refused the change. Otherwise the change may or may not have been applied.
    static func changeFailure(_ error: any Error, on macName: String) -> String {
        if case .refused(let message) = error as? HostLinkError { return message }
        return "\(macName) did not confirm the change: \(error.localizedDescription)"
    }
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
        try await macs.synchronizeJobOptions(beforeRegistering: id)
        try await change(.install(request))
    }

    func markUnregistering(_ runner: String, from repositoryID: Int) async throws {
        try await change(.markUnregistering(runner: runner, repositoryID: repositoryID))
    }

    func markRemoved(_ runner: String) async throws { try await change(.markRemoved(runner: runner)) }

    func markLabelsApplied(_ labels: [String]) async throws { try await change(.markLabelsApplied(labels)) }

    private func change(_ request: RunnerRequest) async throws {
        guard case .completed = try await macs.requestRunners(request, from: id) else { throw HostLinkError.unexpectedReply }
    }
}

/// The Macs that this Mac paired with, and whether each one can be reached: the Macs that a host manages, or the
/// hosts that a dashboard shows.
@MainActor @Observable
final class PairedMacs: MacList {
    enum Status: Codable, Equatable, Sendable {
        /// The Mac does not advertise this pairing's service on the local network.
        case notFound
        case checking
        case online
        /// The Mac no longer has this pairing.
        case rejected
        /// The Mac runs another version of the app, and one of the Macs cannot read the other's messages.
        case incompatible(VersionMismatch)
        case unreachable(String)
    }

    /// A Mac that waits to pair.
    struct PairableMac: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        /// The version of the Mac's messages.
        var version = HostLink.version
    }

    /// The code that the person compares with the one the Mac shows while pairing.
    struct CodeConfirmation: Codable, Equatable, Sendable {
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
    /// How often a host is asked for its sign-in code while GitHub has not issued it.
    static let signInCodeInterval = Duration.milliseconds(500)

    private let store: any SecretStore
    private let name: String
    /// What this Mac does with the Macs it pairs with.
    let role: PairingRole
    private let browses: Bool
    private let version: Int
    private let openURL: @MainActor (URL) -> Bool
    private(set) var macs: [PairedMac] = []
    private(set) var statuses: [HostPairing.ID: Status] = [:]
    /// Kept while a Mac is not found, so that its pane can show when the settings were last read.
    private(set) var settings: [HostPairing.ID: PairedMacSettings] = [:]
    private(set) var pairableMacs: [PairableMac] = []
    /// How many sheets and dashboards look for Macs that wait to pair.
    private var discoveryUsers = 0
    /// Whether this Mac lists the Macs that wait to pair.
    var isDiscovering: Bool { discoveryUsers > 0 }
    /// The Macs that each host manages, which a dashboard reaches through that host.
    private var relayed: [HostPairing.ID: RelayedMacs] = [:]
    private(set) var message: String?
    private(set) var discoveryMessage: String?
    private(set) var codeConfirmation: CodeConfirmation?
    private var confirmation: (id: UUID, continuation: CheckedContinuation<Void, any Error>)?
    /// Whether this Mac is pairing with a Mac. One pairing shows its code at a time.
    private(set) var isPairing = false
    static let alreadyPairing = HostLinkError.refused("\(HostPane.macName) is already pairing with a Mac.")
    @ObservationIgnored weak var jobOptionsOwner: HostSettingsModel?
    private var jobOptionsUpdates: [HostPairing.ID: (endpoint: NWEndpoint, task: Task<HostSettingsReport, any Error>)] = [:]
    private var endpoints: [HostPairing.ID: NWEndpoint] = [:]
    func endpoint(for mac: PairedMac) -> NWEndpoint? { endpoints[mac.id] }
    /// Every management service found, by pairing ID. A Mac advertises its new pairing before this host saves it.
    private var advertised: [HostPairing.ID: NWEndpoint] = [:]
    /// The found services that advertise no version. Those Macs run a version from before messages carried one, and
    /// do not answer a message that does.
    private var unversioned: Set<HostPairing.ID> = []
    @ObservationIgnored private var statusChecks: [HostPairing.ID: Task<Void, Never>] = [:]
    private var isShuttingDown = false
    private var browsing: Task<Void, Never>?
    private var pairableBrowsing: Task<Void, Never>?

    /// - Parameters:
    ///   - browses: Whether to find Macs with Bonjour. Tests pass endpoints instead.
    ///   - version: The version of this Mac's messages.
    ///   - openURL: Opens GitHub's pages in this Mac's browser for a host that a dashboard shows.
    init(
        store: any SecretStore, name: String, role: PairingRole, browses: Bool = true, version: Int = HostLink.version,
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.store = store
        self.name = name
        self.role = role
        self.browses = browses
        self.version = version
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
    func settings(of id: HostPairing.ID) -> PairedMacSettings? { settings[id] }
    var pairedWith: MacReference { .thisMac }
    var listedMacs: [ListedMac] { macs.map(\.listed) }
    var waitingMacs: [WaitingMac] {
        pairableMacs.map { mac in
            WaitingMac(
                id: mac.id, name: mac.name,
                // The Mac answers only its own version, so the Macs could not exchange settings after they paired.
                mismatch: mac.version < HostLink.oldestVersion ? .older : nil
            )
        }
    }

    /// The Macs that a host manages, for the dashboard that shows the host.
    func macsManaged(by host: HostPairing.ID) -> RelayedMacs {
        if let macs = relayed[host] { return macs }
        let macs = RelayedMacs(hosts: self, host: host)
        relayed[host] = macs
        return macs
    }

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
        isShuttingDown = true
        let tasks = [browsing, pairableBrowsing].compactMap { $0 } + statusChecks.values
        let updates = jobOptionsUpdates.values.map(\.task)
        statusChecks.removeAll()
        browsing = nil
        pairableBrowsing = nil
        for task in tasks { task.cancel() }
        for update in updates { update.cancel() }
        for task in tasks { await task.value }
        for update in updates { _ = await update.result }
    }

    /// Lists Macs that wait to pair with a Mac of this role until `stopDiscoveringPairableMacs()`. This Mac keeps
    /// looking until everyone who started has stopped.
    func discoverPairableMacs() {
        discoveryUsers += 1
        guard discoveryUsers == 1 else { return }
        discoveryMessage = nil
        guard browses else { return }
        pairableBrowsing = Task {
            // The browser calls these handlers on the main actor, where they are created.
            let browser = NetworkBrowser(for: .bonjour(HostLink.pairingService, includeTxtRecord: true))
                .onStateUpdate { _, state in
                    guard case .waiting(let error) = state else { return }
                    self.showDiscoveryWaiting(error)
                }
            do {
                try await browser.run { found in
                    // A Mac waits for one role, and refuses a request for the other.
                    self.pairableMacsChanged(found.filter { $0.txtRecord[HostLink.roleKeyName] == self.role.rawValue }.map {
                        // A Mac that advertises no version runs one from before messages carried a version.
                        PairableMac(
                            id: $0.id, name: $0.name, endpoint: $0.nwEndpoint,
                            version: $0.txtRecord[HostLink.versionKeyName].flatMap { Int($0) } ?? 0
                        )
                    })
                }
            } catch is CancellationError {
            } catch {
                showDiscoveryWaiting(error)
            }
        }
    }

    func stopDiscoveringPairableMacs() {
        guard discoveryUsers > 0 else { return }
        discoveryUsers -= 1
        guard discoveryUsers == 0 else { return }
        pairableBrowsing?.cancel()
        pairableBrowsing = nil
        pairableMacs = []
        discoveryMessage = nil
    }

    /// Pairs with a Mac that `pairableMacs` lists.
    func pair(with id: WaitingMac.ID) async throws -> ListedMac {
        guard let mac = pairableMacs.first(where: { $0.id == id }) else {
            throw HostLinkError.unreachable("The Mac is no longer waiting to pair.")
        }
        guard mac.version >= HostLink.oldestVersion else { throw HostLinkError.incompatible(.older) }
        return try await pair(at: mac.endpoint).listed
    }

    /// Pairs with the Mac at `endpoint`, replacing an earlier pairing with the same Mac.
    ///
    /// The pairing finishes after the person confirms `codeConfirmation` with `confirmCode()` and allows the
    /// pairing on the Mac.
    @discardableResult
    func pair(at endpoint: NWEndpoint) async throws -> PairedMac {
        guard !isPairing else { throw Self.alreadyPairing }
        isPairing = true
        defer {
            isPairing = false
            codeConfirmation = nil
        }
        let (pairing, hostID) = try await HostLink.requestPairing(
            at: endpoint, pairingID: UUID(), requesterName: name, role: role, version: version
        ) { macName, code in
            try await self.waitForConfirmation(of: code, from: macName)
        }
        let macName = pairing.name
        let mac = PairedMac(pairing: pairing, hostID: hostID)
        // The pairing took as long as the person or a command needed, and another process may have changed the list.
        reload()
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
                    try? await send(.unpair, to: mac, at: endpoint)
                } else {
                    nil
                }
                if case .unpaired? = reply {} else { keepsEarlierPairing = true }
            }
            setEndpoint(nil, for: mac.id)
            forgetSettings(of: mac.id)
        }
        // The list may have been read again while the earlier pairing was told, so the new one joins what it is now.
        macs = macs.filter { $0.hostID != hostID } + [mac]
        settings[mac.id] = PairedMacSettings()
        message = keepsEarlierPairing
            ? "\(macName) could not be told to forget this Mac's earlier pairing. It lists this Mac twice under Dashboards until you remove one there."
            : nil
        if browsing == nil { start() } else { advertisedServicesChanged() }
        return mac
    }

    /// Pairs with a Mac that `pairableMacs` lists, for a command: the code that the Mac shows is compared with this
    /// Mac's in place of a person comparing the two.
    ///
    /// - Parameters:
    ///   - showCode: Called with this Mac's code once the Macs exchanged keys.
    ///   - otherCode: Returns the code that the Mac shows. The pairing ends without a pairing if it differs. It is
    ///     not waited for once the Mac refused or left.
    func pair(
        with id: WaitingMac.ID, showCode: (CodeConfirmation) throws -> Void,
        otherCode: @escaping @MainActor () async throws -> String
    ) async throws -> ListedMac {
        // Set when a task ended. The pairing ends before a code is shown, or while the other code is awaited, if the
        // Mac refuses or leaves.
        final class Outcome<Value> { var result: Result<Value, any Error>? }
        let paired = Outcome<ListedMac>()
        let pairing = Task {
            do { paired.result = .success(try await pair(with: id)) } catch { paired.result = .failure(error) }
        }
        let other = Outcome<String>()
        var reading: Task<Void, Never>?
        do {
            while codeConfirmation == nil {
                if let result = paired.result { return try result.get() }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let shown = codeConfirmation else { throw HostLinkError.unexpectedReply }
            try showCode(shown)
            reading = Task {
                do { other.result = .success(try await otherCode()) } catch { other.result = .failure(error) }
            }
            while other.result == nil {
                if let result = paired.result {
                    _ = try result.get()
                    throw HostLinkError.unexpectedReply
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let code = try other.result?.get(), code == shown.code else {
                let code = (try? other.result?.get()) ?? ""
                throw HostLinkError.refused(
                    "\(shown.macName) shows the code \(code), and this Mac shows \(shown.code) for it. The Macs did not pair."
                )
            }
            confirmCode()
            await pairing.value
            guard let result = paired.result else { throw HostLinkError.unexpectedReply }
            return try result.get()
        } catch {
            reading?.cancel()
            pairing.cancel()
            await pairing.value
            throw error
        }
    }

    /// Reads the paired Macs again after another process changed them in the store, as a command does for a
    /// dashboard that is open, so that this list is not saved over that change.
    func reload() {
        let saved: [PairedMac]
        do {
            saved = try store.read().map { try JSONDecoder().decode([PairedMac].self, from: $0) } ?? []
        } catch {
            message = "Could not read the paired Macs: \(error.localizedDescription)"
            return
        }
        guard saved != macs else { return }
        for mac in macs where !saved.contains(where: { $0.id == mac.id }) {
            setEndpoint(nil, for: mac.id)
            forgetSettings(of: mac.id)
        }
        for mac in saved where settings[mac.id] == nil { settings[mac.id] = PairedMacSettings() }
        macs = saved
        if macs.isEmpty {
            browsing?.cancel()
            browsing = nil
            advertised = [:]
        } else if browsing == nil {
            start()
        } else {
            advertisedServicesChanged()
        }
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
                    let reply = try await send(.unpair, to: mac, at: endpoint)
                    if case .refused(let message) = reply { throw HostLinkError.refused(message) }
                    guard case .unpaired = reply else { throw HostLinkError.unexpectedReply }
                } catch {
                    notice = "\(mac.name) could not be told: \(error.localizedDescription) \(remainingAccess(on: mac.name))"
                }
            } else {
                notice = "\(mac.name) was not found on the local network. \(remainingAccess(on: mac.name))"
            }
        }
        // Telling the Mac took a moment, in which another process may have changed the list.
        reload()
        let next = macs.filter { $0.id != id }
        do {
            try save(next)
        } catch {
            message = "Could not remove \(mac.name): \(error.localizedDescription)"
            return
        }
        macs = next
        setEndpoint(nil, for: id)
        forgetSettings(of: id)
        message = notice
        if macs.isEmpty {
            browsing?.cancel()
            browsing = nil
            advertised = [:]
        }
    }

    func synchronizeJobOptions(beforeRegistering id: HostPairing.ID) async throws {
        guard let mac = mac(id), let endpoint = endpoints[id] else { throw HostLinkError.unreachable("The runner is offline.") }
        _ = try await synchronizedSettings(of: mac, at: endpoint)
    }

    /// Recheck after each transfer: the host can be edited while a runner is receiving an older save.
    func synchronizedSettings(of mac: PairedMac, at endpoint: NWEndpoint, report: HostSettingsReport? = nil) async throws -> HostSettingsReport {
        guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
        guard let owner = jobOptionsOwner else {
            if let report { return report }
            return try await requestSettings(.read, from: mac, at: endpoint)
        }
        var initial = report
        while let update = jobOptionsUpdates[mac.id] {
            if update.endpoint == endpoint { return try await update.task.value }
            // The former endpoint may already have received its write. Finish it before reading the new endpoint.
            _ = await update.task.result
            initial = nil
        }
        guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
        let update = Task {
            defer { jobOptionsUpdates[mac.id] = nil }
            var report: HostSettingsReport = if let initial { initial } else { try await requestSettings(.read, from: mac, at: endpoint) }
            while true {
                guard endpoints[mac.id] == endpoint else { throw HostLinkError.unreachable("\(mac.name)'s address changed.") }
                guard let desired = owner.jobOptions?.enabledEntries else {
                    throw HostSettingsError(owner.jobOptionsReadError ?? "Could not read the host's job defaults.")
                }
                if let error = report.jobOptionsReadError { throw HostSettingsError(error) }
                if report.jobOptions == desired { break }
                guard report.jobOptions != nil else {
                    if desired == HostJobOptions() { break }
                    throw HostSettingsError("Update XcodeHomeRunner on \(mac.name) to receive this host’s job defaults.")
                }
                let reply = try await send(.syncJobOptions(desired), to: mac, at: endpoint)
                if case .refused(let reason) = reply { throw HostLinkError.refused(reason) }
                guard case .settings(let saved) = reply, saved.jobOptions == desired else { throw HostLinkError.unexpectedReply }
                report = saved
            }
            return report
        }
        jobOptionsUpdates[mac.id] = (endpoint, update)
        return try await update.value
    }

    var jobOptionsSyncErrors: [String] {
        macs.compactMap { mac in settings[mac.id]?.jobOptionsSyncError.map { "\(mac.name): \($0)" } }
    }

    /// Disconnected runners receive the current settings when their regular status checks resume.
    func distributeJobOptions() async {
        for mac in macs {
            guard let endpoint = endpoints[mac.id] else { continue }
            var syncError: String?
            do {
                _ = try await synchronizedSettings(of: mac, at: endpoint)
            } catch { syncError = error.localizedDescription }
            if endpoints[mac.id] == endpoint { settings[mac.id]?.jobOptionsSyncError = syncError }
        }
    }

    /// Reads the settings of the Mac at `endpoint`, which also shows whether it accepts this Mac. Browsing calls this
    /// when a paired Mac is found.
    func checkStatus(of id: HostPairing.ID, at endpoint: NWEndpoint) async {
        guard !isShuttingDown, !Task.isCancelled, let mac = mac(id) else { return }
        setEndpoint(endpoint, for: id)
        guard statusChecks[id] == nil else { return }
        if statuses[id] == nil || statuses[id] == .notFound { statuses[id] = .checking }
        // Closing a pane cancels its watch. The shared read must still publish its answer and release this Mac.
        let task = Task {
            await readStatus(of: mac, at: endpoint)
            if !Task.isCancelled { statusChecks[id] = nil }
        }
        statusChecks[id] = task
        await task.value
    }

    private func readStatus(of mac: PairedMac, at endpoint: NWEndpoint) async {
        let id = mac.id
        let changeCount = settings[id]?.changeCount
        let status: Status
        var report: HostSettingsReport?
        var github: GitHubReport?
        var managed: ManagedMacsReport?
        do {
            let overlapsFormerEndpoint = jobOptionsUpdates[id].map { $0.endpoint != endpoint } ?? false
            let read = try await requestSettings(.read, from: mac, at: endpoint)
            report = read
            if role == .manager {
                // An older runner can still be managed when it cannot apply build defaults.
                var syncError: String?
                do {
                    // The write at the former endpoint can finish after this snapshot but before its reply arrives.
                    report = try await synchronizedSettings(of: mac, at: endpoint, report: overlapsFormerEndpoint ? nil : read)
                } catch { syncError = error.localizedDescription }
                guard !Task.isCancelled else { return }
                settings[id]?.jobOptionsSyncError = syncError
            }
            // A dashboard shows the host's GitHub settings and the Macs it manages too. A managing host has its own.
            if role == .dashboard {
                github = try await requestGitHub(.read, from: mac, at: endpoint)
                managed = try await requestManagedMacs(.read(refreshing: nil), from: mac, at: endpoint)
            }
            status = .online
        } catch HostLinkError.rejected {
            status = .rejected
        } catch HostLinkError.incompatible(let mismatch) {
            status = .incompatible(mismatch)
        } catch {
            status = .unreachable(error.localizedDescription)
        }
        // The pairing or endpoint may have changed while the request was in flight.
        guard !Task.isCancelled, self.mac(id) != nil, endpoints[id] == endpoint else { return }
        statuses[id] = status
        if let report, let settings = settings[id], settings.changeCount == changeCount, !settings.isChanging {
            settings.show(report)
            if let github { settings.show(github) }
        }
        if let managed { macsManaged(by: id).show(managed) }
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
        guard let mac = mac(id), let settings = settings[id] else { return false }
        return await settings.applyPoolConfiguration(on: mac.name) { changes in
            try await self.requestSettings(.configurePool(changes), from: mac)
        }
    }

    func saveStorageDirectory(of id: HostPairing.ID) async {
        guard let mac = mac(id), let settings = settings[id] else { return }
        await settings.saveStorageDirectory(on: mac.name) { directory in
            try await self.requestSettings(.saveStorage(directory: directory), from: mac)
        }
    }

    func saveXcodeSelection(of id: HostPairing.ID) async {
        guard let mac = mac(id), let settings = settings[id] else { return }
        await settings.saveXcodeSelection(on: mac.name) { developerDirectory in
            try await self.requestSettings(.saveXcode(developerDirectory: developerDirectory), from: mac)
        }
    }

    func saveJobOptions(_ edits: HostJobOptions.Edits, of id: HostPairing.ID) async throws {
        guard let mac = mac(id), let settings = settings[id] else { throw HostLinkError.unexpectedReply }
        try await settings.saveJobOptions {
            try await self.requestSettings(.saveJobOptions(edits), from: mac)
        }
    }

    func saveBuildService(of id: HostPairing.ID) async {
        guard let mac = mac(id), let settings = settings[id] else { return }
        await settings.saveBuildService(on: mac.name) { path in
            try await self.requestSettings(.saveBuildService(path: path), from: mac)
        }
    }

    @discardableResult
    func saveRunnerLabels(of id: HostPairing.ID) async -> Bool {
        guard let mac = mac(id), let settings = settings[id] else { return false }
        return await settings.saveRunnerLabels(on: mac.name) { labels in
            try await self.requestSettings(.saveRunnerLabels(labels), from: mac)
        }
    }

    func setPaused(_ isPaused: Bool, of id: HostPairing.ID) async {
        guard let mac = mac(id), let settings = settings[id] else { return }
        await settings.setPaused(isPaused, on: mac.name) { isPaused in
            try await self.requestSettings(.setPaused(isPaused), from: mac)
        }
    }

    func restart(_ id: HostPairing.ID) async {
        guard let mac = mac(id), let settings = settings[id] else { return }
        await settings.restart(on: mac.name) { try await self.requestSettings(.restart, from: mac) }
    }

    /// Changes a Mac's settings for a dashboard, and shows the result in this host's pane for the Mac as well.
    func relay(_ request: HostSettingsRequest, to id: HostPairing.ID) async throws -> HostSettingsReport {
        guard let mac = mac(id), let settings = settings[id] else {
            throw HostLinkError.unreachable("The Mac is no longer paired.")
        }
        settings.beginChange()
        defer { settings.endChange() }
        let report = try await requestSettings(request, from: mac)
        settings.show(report)
        return report
    }

    /// Reads a Mac's settings now, if it is found on the network.
    func refresh(_ id: HostPairing.ID) async {
        if let endpoint = endpoints[id] { await checkStatus(of: id, at: endpoint) }
    }

    /// Sends a request to a paired Mac. A Mac that advertises no version does not answer a message that carries one,
    /// so it is not asked.
    private func send(
        _ request: HostLinkRequest, to mac: PairedMac, at endpoint: NWEndpoint, timeout: Duration = HostLink.requestTimeout
    ) async throws -> HostLinkReply {
        guard !unversioned.contains(mac.id) else { throw HostLinkError.incompatible(.older) }
        return try await HostLink.send(
            request, to: endpoint, key: mac.pairing.symmetricKey, identity: mac.id.uuidString, version: version, timeout: timeout
        )
    }

    private func requestSettings(
        _ request: HostSettingsRequest, from mac: PairedMac, at endpoint: NWEndpoint? = nil
    ) async throws -> HostSettingsReport {
        guard let endpoint = endpoint ?? endpoints[mac.id] else {
            throw HostLinkError.unreachable("\(mac.name) was not found on the local network.")
        }
        let request = HostLinkRequest.settings(request)
        let reply = try await send(request, to: mac, at: endpoint, timeout: request.replyTimeout)
        switch reply {
        case .settings(let report): return report
        case .refused(let message): throw HostLinkError.refused(message)
        default: throw HostLinkError.unexpectedReply
        }
    }

    /// Starts the host's GitHub sign-in and, once GitHub issued its code, opens GitHub's page for it in this Mac's
    /// browser.
    func signIn(to id: HostPairing.ID) async {
        guard let mac = mac(id), let settings = settings[id], var report = await changeGitHub(.signIn, of: id) else { return }
        // The host answers before GitHub issues the code, so the sign-in can be cancelled while it waits.
        while report.isConnecting, report.signInCode == nil {
            let changeCount = settings.changeCount
            do {
                try await Task.sleep(for: Self.signInCodeInterval)
                report = try await requestGitHub(.read, from: mac)
            } catch is CancellationError {
                return
            } catch {
                settings.githubError = PairedMacSettings.changeFailure(error, on: mac.name)
                return
            }
            // A change made meanwhile, such as cancelling, already showed newer settings than this read.
            guard settings.changeCount == changeCount, !settings.isChanging else { return }
            settings.show(report)
        }
        if let code = report.signInCode, !openURL(code.verificationURI) {
            settings.githubError = "Could not open your browser."
        }
    }

    func cancelSignIn(to id: HostPairing.ID) async { await changeGitHub(.cancelSignIn, of: id) }
    func signOut(of id: HostPairing.ID, confirmedLogin: String) async {
        await changeGitHub(.disconnectAccount(confirmedLogin), of: id)
    }
    func reloadRepositories(of id: HostPairing.ID) async { await changeGitHub(.reloadRepositories, of: id) }

    /// Sends explicit edits, or asks the host to retry registration against its current saved selection.
    func applyRepositorySelection(_ selection: Set<Int>?, of id: HostPairing.ID) async {
        await changeGitHub(selection.map(GitHubRequest.applySelection) ?? .retryRunnerRegistration, of: id)
    }

    /// Opens the page that chooses the repositories of the host's GitHub App, in this Mac's browser.
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
            settings.githubError = PairedMacSettings.changeFailure(error, on: mac.name)
            return nil
        }
    }

    private func requestGitHub(
        _ request: GitHubRequest, from mac: PairedMac, at endpoint: NWEndpoint? = nil
    ) async throws -> GitHubReport {
        guard let endpoint = endpoint ?? endpoints[mac.id] else {
            throw HostLinkError.unreachable("\(mac.name) was not found on the local network.")
        }
        let request = HostLinkRequest.github(request)
        let reply = try await send(request, to: mac, at: endpoint, timeout: request.replyTimeout)
        switch reply {
        case .github(let report): return report
        case .refused(let message): throw HostLinkError.refused(message)
        default: throw HostLinkError.unexpectedReply
        }
    }

    /// Sends a request about the Macs that a host manages, for the dashboard that shows the host.
    func requestManagedMacs(_ request: ManagedMacsRequest, from id: HostPairing.ID) async throws -> ManagedMacsReport {
        guard let mac = mac(id) else { throw HostLinkError.unreachable("The Mac is no longer paired.") }
        return try await requestManagedMacs(request, from: mac)
    }

    private func requestManagedMacs(
        _ request: ManagedMacsRequest, from mac: PairedMac, at endpoint: NWEndpoint? = nil
    ) async throws -> ManagedMacsReport {
        guard let endpoint = endpoint ?? endpoints[mac.id] else {
            throw HostLinkError.unreachable("\(mac.name) was not found on the local network.")
        }
        let request = HostLinkRequest.macs(request)
        let reply = try await send(request, to: mac, at: endpoint, timeout: request.replyTimeout)
        switch reply {
        case .macs(let report): return report
        case .refused(let message): throw HostLinkError.refused(message)
        default: throw HostLinkError.unexpectedReply
        }
    }

    /// Reads a Mac's settings now, without showing them in its pane.
    func readSettings(of id: HostPairing.ID) async throws -> HostSettingsReport {
        guard let mac = mac(id) else { throw HostLinkError.unreachable("The Mac is no longer paired.") }
        return try await requestSettings(.read, from: mac)
    }

    func readActivity(of id: HostPairing.ID, after clock: RunnerMetricSample.SampleClock?) async throws -> [RunnerMetricSample] {
        try await readActivity(of: nil, through: id, after: clock)
    }

    func readActivity(
        of managedMac: HostPairing.ID?, through id: HostPairing.ID, after clock: RunnerMetricSample.SampleClock?
    ) async throws -> [RunnerMetricSample] {
        guard let mac = mac(id), let endpoint = endpoints[id] else { throw HostLinkError.unreachable("The Mac was not found.") }
        let request = HostLinkRequest.activity(mac: managedMac, after: clock)
        switch try await send(request, to: mac, at: endpoint, timeout: request.replyTimeout) {
        case .activity(let samples): return samples
        case .refused(let reason): throw HostLinkError.refused(reason)
        default: throw HostLinkError.unexpectedReply
        }
    }

    /// Sends a request about a Mac's runner folders, and throws the Mac's refusal.
    func requestRunners(_ request: RunnerRequest, from id: HostPairing.ID) async throws -> HostLinkReply {
        guard let mac = mac(id) else { throw HostLinkError.unreachable("The Mac is no longer paired.") }
        guard let endpoint = endpoints[mac.id] else {
            throw HostLinkError.unreachable("\(mac.name) was not found on the local network.")
        }
        let request = HostLinkRequest.runners(request)
        let reply = try await send(request, to: mac, at: endpoint, timeout: request.replyTimeout)
        if case .refused(let message) = reply { throw HostLinkError.refused(message) }
        return reply
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
        // A Mac with a host shows its dashboard from the host's process, and a dashboard opened before the host was
        // set up runs in another one. Each reads the hosts again after the other saved them.
        if role == .dashboard, browses { HostControl.dashboardHostsChanged() }
    }

    private func setEndpoint(_ endpoint: NWEndpoint?, for id: HostPairing.ID) {
        guard endpoints[id] != endpoint else { return }
        statusChecks.removeValue(forKey: id)?.cancel()
        statuses[id] = nil
        endpoints[id] = endpoint
    }

    /// Forgets what was read from a Mac that left the list.
    private func forgetSettings(of id: HostPairing.ID) {
        settings[id] = nil
        relayed[id] = nil
    }

    private func managementServicesChanged(_ found: [Bonjour.Endpoint]) {
        advertised = [:]
        unversioned = []
        for service in found {
            guard let value = service.txtRecord[HostLink.pairingKeyName], let id = UUID(uuidString: value) else { continue }
            advertised[id] = service.nwEndpoint
            if service.txtRecord[HostLink.versionKeyName] == nil { unversioned.insert(id) }
        }
        advertisedServicesChanged()
    }

    /// Checks the paired Macs whose service appeared or moved, and forgets the status of the ones no longer found.
    private func advertisedServicesChanged() {
        let current = advertised.filter { mac($0.key) != nil }
        let previous = endpoints
        for id in previous.keys where current[id] == nil { setEndpoint(nil, for: id) }
        for (id, endpoint) in current where previous[id] != endpoint {
            setEndpoint(endpoint, for: id)
            Task { await refresh(id) }
        }
    }

    /// Poll slots directly so a concurrent dashboard status check cannot substitute an older pool snapshot.
    func readRunnerSlots() async -> [RunnerMacStatus] {
        let listed = macs
        return await withTaskGroup(of: RunnerMacStatus.self) { group in
            for mac in listed {
                let endpoint = endpoints[mac.id]
                group.addTask {
                    let slots: RunnerSlots
                    do {
                        guard let endpoint else { throw HostLinkError.unreachable(mac.name) }
                        guard case .runnerSlots(let report) = try await self.send(.runnerSlots, to: mac, at: endpoint, timeout: HostLinkRequest.runnerSlots.replyTimeout) else {
                            throw HostLinkError.unexpectedReply
                        }
                        slots = report
                    } catch {
                        slots = RunnerSlots(state: "unknown", available: nil, reason: error.localizedDescription)
                    }
                    return RunnerMacStatus(id: mac.id, name: mac.name, slots: slots)
                }
            }
            var reports: [HostPairing.ID: RunnerMacStatus] = [:]
            for await report in group {
                if let id = report.id { reports[id] = report }
            }
            return macs.compactMap { reports[$0.id] }
        }
    }

    private func checkFoundMacs() async {
        await withTaskGroup { group in
            for id in endpoints.keys {
                group.addTask { await self.refresh(id) }
            }
        }
    }

    /// Lists the Macs found waiting to pair. Browsing calls this, and tests call it in place of Bonjour.
    func pairableMacsChanged(_ found: [PairableMac]) {
        guard isDiscovering else { return }
        discoveryMessage = nil
        pairableMacs = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

extension HostLinkRequest {
    /// How long a paired Mac has to answer the request. A Mac answers a read at once, and a change once it applied
    /// it, which can take a download or a call to GitHub.
    @MainActor var replyTimeout: Duration {
        switch self {
        case .settings(.read), .github(.read):
            HostLink.requestTimeout
        case .settings, .syncJobOptions, .github:
            PairedMacs.changeTimeout
        case .macs(let request):
            // The host reads or changes one of its Macs before it answers, within its own time limits.
            switch request {
            case .read(refreshing: nil), .discover, .pair, .confirmCode, .cancelPairing: HostLink.requestTimeout
            case .read, .listRunners: HostLink.requestTimeout * 3
            case .configurePool, .saveStorage, .saveXcode, .saveBuildService, .saveRunnerLabels, .setPaused, .restart,
                 .remove:
                PairedMacs.changeTimeout
            }
        case .runners(let request):
            switch request {
            case .prepareArchive: PairedMacs.downloadTimeout
            case .install: PairedMacs.changeTimeout
            default: HostLink.requestTimeout
            }
        case .runnerSlots: HostLink.requestTimeout * 2
        case .activity(let mac, _): mac == nil ? HostLink.requestTimeout : HostLink.requestTimeout * 2
        case .operation, .unpair:
            HostLink.requestTimeout
        }
    }
}
