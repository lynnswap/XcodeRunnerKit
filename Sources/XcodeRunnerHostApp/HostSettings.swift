import Foundation
import Observation
import SwiftUI
import XcodeRunnerHostSupport
import XcodeRunnerKit

enum HostState: String, Codable, Sendable {
    case starting = "Starting"
    case preparingStorage = "Preparing storage"
    case waitingForStorage = "Waiting for storage"
    case running = "Running"
    case needsAttention = "Needs attention"
    case stopping = "Stopping"
}

enum RunnerServiceState: String, Codable, Sendable {
    case starting = "Starting"
    case running = "Running"
    case stopped = "Stopped"
    case failed = "Needs attention"
    case individualService = "Individual service"
}

struct RunnerSettingsRow: Codable, Equatable, Identifiable, Sendable {
    let directory: URL
    let name: String
    let state: RunnerServiceState
    let configurationError: String?

    var id: URL { directory }

    static func read(_ runner: RunnerDirectory, state: RunnerServiceState) -> Self {
        struct Registration: Decodable {
            var agentName: String?
        }
        do {
            return Self(
                directory: runner.url, name: try runner.registration(as: Registration.self).agentName ?? runner.name, state: state,
                configurationError: nil
            )
        } catch {
            return Self(
                directory: runner.url, name: runner.name, state: state,
                configurationError: "Could not read this runner’s settings: \(error.localizedDescription)"
            )
        }
    }
}

/// A job limit and Simulator retention being edited, for this Mac or for a Mac paired with it.
struct PoolSettingsDraft: Equatable {
    /// The edited settings. A setting that matches the saved one is `nil`, so Apply leaves its saved value as it is.
    struct Changes: Codable, Equatable, Sendable {
        var maximumConcurrentJobs: Int?
        var simulatorRetention: HostExecutionPool.SimulatorRetention?
    }

    /// The saved settings that the inputs were last updated from.
    private(set) var base = HostExecutionPool.Configuration(maximumConcurrentJobs: HostInstallation.defaultMaximumConcurrentJobs)
    var capacityInput = String(HostInstallation.defaultMaximumConcurrentJobs)
    var keepsSimulatorsForever = false
    var simulatorIdleRetentionInput = "20"

    /// Shows newly read settings in the inputs that were not edited.
    mutating func update(from saved: HostExecutionPool.Configuration?) {
        let next = saved ?? HostExecutionPool.Configuration(maximumConcurrentJobs: HostInstallation.defaultMaximumConcurrentJobs)
        if saved != nil, capacityInput == String(base.maximumConcurrentJobs) {
            capacityInput = String(next.maximumConcurrentJobs)
        }
        if shows(base.simulatorRetention) { show(next.simulatorRetention) }
        base = next
    }

    /// Shows the settings that Apply saved in every input.
    mutating func reset(to saved: HostExecutionPool.Configuration) {
        capacityInput = String(saved.maximumConcurrentJobs)
        show(saved.simulatorRetention)
        base = saved
    }

    /// The edited settings, or the error that the settings window shows for an invalid input.
    ///
    /// - Parameter isNewPool: Whether every setting is included, because the pool has none saved.
    func changes(isNewPool: Bool) throws(HostSettingsError) -> Changes {
        guard let capacity = Int(capacityInput), capacity > 0 else {
            throw HostSettingsError("Enter a positive whole number of concurrent jobs.")
        }
        let retention: HostExecutionPool.SimulatorRetention
        if keepsSimulatorsForever {
            retention = .forever
        } else {
            guard let minutes = Int(simulatorIdleRetentionInput), minutes > 0 else {
                throw HostSettingsError("Enter a positive whole number of idle minutes.")
            }
            retention = .idleTimeout(minutes: minutes)
        }
        return Changes(
            maximumConcurrentJobs: isNewPool || capacity != base.maximumConcurrentJobs ? capacity : nil,
            simulatorRetention: isNewPool || retention != base.simulatorRetention ? retention : nil
        )
    }

    private func shows(_ retention: HostExecutionPool.SimulatorRetention) -> Bool {
        switch retention {
        case .forever: keepsSimulatorsForever
        case .idleTimeout(let minutes): !keepsSimulatorsForever && simulatorIdleRetentionInput == String(minutes)
        }
    }

    private mutating func show(_ retention: HostExecutionPool.SimulatorRetention) {
        switch retention {
        case .forever: keepsSimulatorsForever = true
        case .idleTimeout(let minutes):
            keepsSimulatorsForever = false
            simulatorIdleRetentionInput = String(minutes)
        }
    }
}

/// A Mac's host status and execution settings, as a window shows them for this Mac and for the Macs paired with it.
@MainActor
protocol HostSettingsDisplay {
    var hostState: HostState { get }
    var runners: [RunnerSettingsRow] { get }
    var runnerScanError: String? { get }
    var poolStatus: HostExecutionPool.Status? { get }
    var hasLoadedPoolStatus: Bool { get }
    var poolError: String? { get }
    var simulatorPoolError: String? { get }
    var configurationCleanupError: String? { get }
    var savedStorageDirectory: URL? { get }
    var activeStorageDirectory: URL? { get }
    var storageError: String? { get }
    var canApplyPoolConfiguration: Bool { get }
    var canEditStorage: Bool { get }
    /// Whether the host can restart itself. A host that launchd did not start cannot.
    var canRestart: Bool { get }
}

extension HostSettingsDisplay {
    /// Whether Apply saves every pool setting, because the pool has none saved.
    var isNewPool: Bool { poolStatus == nil && poolError == nil }

    var jobSummary: String {
        guard let status = poolStatus else {
            if !hasLoadedPoolStatus { return "Checking…" }
            return poolError == nil ? "Not configured" : "Unavailable"
        }
        return "\(status.activeJobCount) running · \(status.waitingJobCount) waiting · Limit \(status.configuration.maximumConcurrentJobs)"
    }

    var admissionMessage: String {
        if !hasLoadedPoolStatus { return "Checking the execution pool…" }
        if poolError != nil { return "The execution pool is unavailable." }
        guard let poolStatus else { return "Set a limit to configure the shared execution pool." }
        if poolStatus.activeJobCount > poolStatus.configuration.maximumConcurrentJobs {
            return "Existing jobs will finish. New jobs wait until the running count falls below the limit."
        }
        if poolStatus.activeJobCount == poolStatus.configuration.maximumConcurrentJobs {
            return "New jobs wait for an available slot."
        }
        return "New jobs can start while slots are available."
    }

    /// Whether a saved storage folder waits for the next host launch.
    var storageChangeIsPending: Bool { savedStorageDirectory != nil && savedStorageDirectory != activeStorageDirectory }

    var storageMessage: String {
        if hostState == .waitingForStorage {
            return "Runner services start when storage becomes available. Folder changes saved now apply on the next host launch."
        }
        if let savedStorageDirectory, savedStorageDirectory != activeStorageDirectory {
            if activeStorageDirectory == nil { return "Saved for the next host launch." }
            return "Saved for the next host launch. Running jobs continue using their current storage."
        }
        if activeStorageDirectory != nil { return "Runner checkouts, build results, and the shared compiler cache use this folder." }
        return "Choose one folder for runner checkouts, build results, and the shared compiler cache."
    }
}

/// What a Mac sends the Macs paired with it about its status and settings.
struct HostSettingsReport: Codable, Equatable, Sendable {
    let hostState: HostState
    let runners: [RunnerSettingsRow]
    let runnerScanError: String?
    let poolStatus: HostExecutionPool.Status?
    let hasLoadedPoolStatus: Bool
    let poolError: String?
    let simulatorPoolError: String?
    let configurationCleanupError: String?
    let savedStorageDirectory: URL?
    let activeStorageDirectory: URL?
    let storageError: String?
    let canApplyPoolConfiguration: Bool
    let canEditStorage: Bool
    let canRestart: Bool

    @MainActor init(_ settings: some HostSettingsDisplay) {
        hostState = settings.hostState
        runners = settings.runners
        runnerScanError = settings.runnerScanError
        poolStatus = settings.poolStatus
        hasLoadedPoolStatus = settings.hasLoadedPoolStatus
        poolError = settings.poolError
        simulatorPoolError = settings.simulatorPoolError
        configurationCleanupError = settings.configurationCleanupError
        savedStorageDirectory = settings.savedStorageDirectory
        activeStorageDirectory = settings.activeStorageDirectory
        storageError = settings.storageError
        canApplyPoolConfiguration = settings.canApplyPoolConfiguration
        canEditStorage = settings.canEditStorage
        canRestart = settings.canRestart
    }
}

// Conforming in the type's declaration would isolate the report to the main actor, where network connections do not
// encode and decode it.
extension HostSettingsReport: HostSettingsDisplay {}

@MainActor @Observable
final class HostSettingsModel: HostSettingsDisplay {
    let installation: HostInstallation
    let pool: HostExecutionPool
    let github: GitHubHostSettings
    /// This Mac's pairings with the host that manages it and the dashboards that show it.
    let management: HostManagement
    /// The Macs that this host manages.
    let managedMacs: PairedMacs
    /// Answers a dashboard's requests about the Macs that this host manages.
    @ObservationIgnored private(set) lazy var managedMacsRelay = ManagedMacsRelay(macs: managedMacs) { [unowned self] in canAddMacs }
    let settingsService: HostSettingsService
    var hostState = HostState.starting
    var runners: [RunnerSettingsRow] = []
    var runnerScanError: String?
    private(set) var poolStatus: HostExecutionPool.Status?
    private(set) var poolError: String?
    private(set) var simulatorPoolError: String?
    private(set) var saveError: String?
    private(set) var configurationCleanupError: String?
    private(set) var isSaving = false
    private(set) var hasLoadedPoolStatus = false
    var poolDraft = PoolSettingsDraft()
    private(set) var activeStorageDirectory: URL?
    private(set) var storageError: String?
    private(set) var storageSaveError: String?
    private(set) var savedStorageDirectory: URL?
    private(set) var isSavingStorage = false
    var storageDirectoryInput = ""
    /// Stops the host and has launchd start it again. `nil` for a host that launchd did not start.
    var restartHost: (@MainActor () -> Void)?

    init(
        installation: HostInstallation, github: GitHubHostSettings? = nil,
        management: HostManagement? = nil, managedMacs: PairedMacs? = nil
    ) {
        self.installation = installation
        // Reading status leaves an unconfigured pool unchanged.
        self.pool = HostExecutionPool(directory: installation.poolDirectory)
        self.settingsService = HostSettingsService(installation: installation, pool: pool)
        self.github = github ?? GitHubHostSettings(installation: installation, pool: pool)
        self.management = management ?? HostManagement(
            store: KeychainSecretStore.managingHost(hostRoot: installation.hostRoot), name: HostPane.macName
        )
        self.managedMacs = managedMacs ?? PairedMacs(
            store: KeychainSecretStore.managedMacs(hostRoot: installation.hostRoot), name: HostPane.macName, role: .manager
        )
        do {
            savedStorageDirectory = try installation.requestedStorageDirectory() ?? installation.storage()?.directory
            storageDirectoryInput = savedStorageDirectory?.path(percentEncoded: false) ?? ""
        } catch {
            storageSaveError = "Could not read the saved storage folder: \(error.localizedDescription)"
        }
        // The Macs paired with this Mac read and change its settings through the owner of this Mac's window.
        self.management.settings = self
        self.github.pairedMacs = self.managedMacs
        self.github.management = self.management
    }

    func storageDidBecomeAvailable(_ storage: HostInstallation.Storage) {
        activeStorageDirectory = storage.directory
        github.storageIsReady = true
        storageError = nil
        if savedStorageDirectory == nil {
            savedStorageDirectory = storage.directory
            storageDirectoryInput = storage.directory.path(percentEncoded: false)
        }
    }

    func storageDidBecomeUnavailable(_ error: any Error) {
        github.storageIsReady = false
        storageError = "Storage is unavailable: \(error.localizedDescription) Retrying automatically."
        hostState = .waitingForStorage
    }

    func storagePreparationFailed(_ error: any Error) {
        github.storageIsReady = false
        storageError = "Could not prepare storage: \(error.localizedDescription)"
        hostState = .needsAttention
    }

    /// Whether the storage folder can be edited and saved. It stays available while the host needs attention.
    var canEditStorage: Bool { !isSavingStorage && hostState != .stopping }

    /// A restart waits for a save in progress, whose folder or limit the next launch would otherwise not have.
    var canRestart: Bool { restartHost != nil && hostState != .stopping && !isSaving && !isSavingStorage }

    /// Restarts the host, which applies a saved storage folder. Runner services stop until it has started again.
    func restart() {
        guard canRestart else { return }
        restartHost?()
    }

    func saveStorageSelection() async {
        guard canEditStorage else { return }
        do {
            storageDirectoryInput = try await saveStorageDirectory(storageDirectoryInput).path(percentEncoded: false)
            storageSaveError = nil
        } catch {
            storageSaveError = error.localizedDescription
        }
    }

    /// Saves a storage folder from this Mac's window or from a Mac paired with it.
    private func saveStorageDirectory(_ path: String) async throws(HostSettingsError) -> URL {
        // Another Mac's pane cannot choose a folder on this Mac, so the message offers only a path.
        guard path.hasPrefix("/") else { throw HostSettingsError("Enter an absolute folder path.") }
        let previous = savedStorageDirectory?.path(percentEncoded: false) ?? ""
        isSavingStorage = true
        defer { isSavingStorage = false }
        do {
            let directory = try await settingsService.requestStorageDirectory(URL(filePath: path))
            savedStorageDirectory = directory
            if storageDirectoryInput == previous { storageDirectoryInput = directory.path(percentEncoded: false) }
            return directory
        } catch {
            throw HostSettingsError("Could not save the storage folder: \(error.localizedDescription)")
        }
    }

    func chooseStorageDirectory() async {
        guard canEditStorage else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Storage Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window = NSApplication.shared.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        if response == .OK, let directory = panel.url {
            storageDirectoryInput = directory.path(percentEncoded: false)
        }
    }

    /// A Mac either manages other Macs or is managed by one, so that one host registers each Mac's runners.
    var canAllowManagement: Bool { managedMacs.macs.isEmpty }
    var canAddMacs: Bool { management.manager == nil && management.pairingWindow?.role != .manager }

    func trimSimulatorPool() async {
        do {
            try await pool.removeExcessSimulators()
            simulatorPoolError = nil
        } catch is CancellationError {
            return
        } catch {
            simulatorPoolError = "Could not clean up idle Simulators: \(error.localizedDescription)"
        }
    }

    var savedSimulatorRetention: HostExecutionPool.SimulatorRetention {
        poolStatus?.configuration.simulatorRetention ?? .idleTimeout(minutes: 20)
    }

    var simulatorRetentionDescription: String {
        if !hasLoadedPoolStatus { return "Checking…" }
        if poolError != nil { return "Unavailable" }
        if poolStatus == nil { return "Not configured" }
        return switch savedSimulatorRetention {
        case .forever: "Keep indefinitely"
        case .idleTimeout(let minutes): "Remove after \(minutes) idle minutes"
        }
    }

    func refreshPoolStatus() async {
        refreshStorageSelection()
        do {
            let status = try await pool.status()
            poolStatus = status
            poolError = nil
            hasLoadedPoolStatus = true
            poolDraft.update(from: status?.configuration)
        } catch is CancellationError {
            return
        } catch {
            poolStatus = nil
            poolError = "Could not read the execution pool: \(error.localizedDescription)"
            hasLoadedPoolStatus = true
        }
    }

    private func refreshStorageSelection() {
        let previousInput = savedStorageDirectory?.path(percentEncoded: false) ?? ""
        do {
            savedStorageDirectory = try installation.requestedStorageDirectory() ?? installation.storage()?.directory
            if storageDirectoryInput == previousInput {
                storageDirectoryInput = savedStorageDirectory?.path(percentEncoded: false) ?? ""
            }
        } catch {
            storageSaveError = "Could not read the saved storage folder: \(error.localizedDescription)"
        }
    }

    /// Saves the default limit on a new host, so runners can register and jobs can start before the limit is edited.
    func configureDefaultPool() async {
        do {
            guard try await pool.status() == nil else { return }
            try await settingsService.configurePool(maximumConcurrentJobs: HostInstallation.defaultMaximumConcurrentJobs)
        } catch is CancellationError {
        } catch {
            saveError = "Could not save the default execution pool settings: \(error.localizedDescription)"
        }
    }

    var canApplyPoolConfiguration: Bool { hasLoadedPoolStatus && !isSaving && !github.isBusy && hostState != .stopping }

    func applyPoolConfiguration() async {
        guard canApplyPoolConfiguration else { return }
        let changes: PoolSettingsDraft.Changes
        do {
            changes = try poolDraft.changes(isNewPool: isNewPool)
        } catch {
            saveError = error.localizedDescription
            return
        }
        let previousCapacity = poolStatus?.configuration.maximumConcurrentJobs
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await savePoolConfiguration(changes)
            saveError = nil
            poolDraft.reset(to: saved)
            await refreshPoolStatus()
            if previousCapacity != saved.maximumConcurrentJobs { await github.synchronize() }
        } catch {
            saveError = "Could not save the execution pool settings: \(error.localizedDescription)"
        }
    }

    /// Answers a paired Mac's request to read or change this Mac's settings, the way this Mac's window does.
    func answer(_ request: HostSettingsRequest) async -> HostLinkReply {
        do {
            switch request {
            case .read: break
            case .configurePool(let changes): try await applyPairedMacChanges(changes)
            case .saveStorage(let directory): try await savePairedMacStorage(directory)
            case .restart: try requireCanRestart()
            }
            return .settings(HostSettingsReport(self))
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Applies a paired Mac's changes. Runners for a changed limit are registered afterwards: by the managing host, or
    /// by this Mac after a dashboard's change.
    private func applyPairedMacChanges(_ changes: PoolSettingsDraft.Changes) async throws(HostSettingsError) {
        guard canApplyPoolConfiguration else {
            throw HostSettingsError("\(HostPane.macName) cannot apply these settings now. Try again in a moment.")
        }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await savePoolConfiguration(changes)
        } catch {
            throw HostSettingsError("Could not save the execution pool settings: \(error.localizedDescription)")
        }
        await refreshPoolStatus()
    }

    /// The caller restarts the host with `restart()` once the paired Mac has the reply.
    private func requireCanRestart() throws(HostSettingsError) {
        guard canRestart else {
            throw HostSettingsError("\(HostPane.macName) cannot restart XcodeHomeRunner by itself. Restart it on that Mac.")
        }
    }

    // With this guard's `throw` inline in `answer(_:)`, the Xcode 27.1 optimizer crashes while compiling it for Release.
    private func savePairedMacStorage(_ directory: String) async throws(HostSettingsError) {
        guard canEditStorage else {
            throw HostSettingsError("\(HostPane.macName) cannot save a storage folder now. Try again in a moment.")
        }
        _ = try await saveStorageDirectory(directory)
    }

    private func savePoolConfiguration(_ changes: PoolSettingsDraft.Changes) async throws -> HostExecutionPool.Configuration {
        do {
            let saved = try await settingsService.configurePool(
                maximumConcurrentJobs: changes.maximumConcurrentJobs, simulatorRetention: changes.simulatorRetention
            )
            configurationCleanupError = nil
            return saved
        } catch let failure as HostExecutionPool.ConfigurationCleanupFailure {
            configurationCleanupError = failure.localizedDescription
            return failure.savedConfiguration
        }
    }
}

@MainActor
struct HostMacSettingsView: View {
    @Bindable var model: HostSettingsModel

    var body: some View {
        Form {
            // Other Macs' changes to this Mac's settings appear below, so who can make them comes first.
            HostManagementSection(model: model)
            HostDashboardsSection(model: model)
            RunnerServicesSection(settings: model) {
                Text("Processes on this Mac. Overview shows each repository's connection and job counts from GitHub.")
            }
            XcodeExecutionSection(
                settings: model, draft: $model.poolDraft, isSaving: model.isSaving, canApply: model.canApplyPoolConfiguration,
                saveError: model.saveError
            ) {
                Task { await model.applyPoolConfiguration() }
            }
            StorageSection(
                settings: model, directory: $model.storageDirectoryInput, isSaving: model.isSavingStorage,
                saveError: model.storageSaveError, mac: .thisMac, isRestarting: model.hostState == .stopping, restartError: nil,
                choose: { Task { await model.chooseStorageDirectory() } }, restart: { model.restart() }
            ) {
                Task { await model.saveStorageSelection() }
            }
        }
    }
}

/// A Mac's runner services, in its own window or in a paired Mac's pane for it.
@MainActor
struct RunnerServicesSection<Settings: HostSettingsDisplay, Footer: View>: View {
    let settings: Settings
    @ViewBuilder let footer: Footer

    var body: some View {
        Section {
            if settings.runners.isEmpty {
                Text(settings.storageError == nil ? "No runners have opted in to this host." : "Runner services have not started because storage needs attention.")
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.runners) { runner in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(runner.name, value: runner.state.rawValue)
                    if runner.state == .individualService {
                        Text("This runner uses its individual service. The host does not start another service for it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = runner.configurationError { ErrorText(error) }
                }
            }
            if let error = settings.runnerScanError { ErrorText(error) }
        } header: {
            Text("Runner Services")
        } footer: {
            footer
        }
    }
}

/// A Mac's job limit and Simulator retention, in its own window or in a paired Mac's pane for it.
@MainActor
struct XcodeExecutionSection<Settings: HostSettingsDisplay>: View {
    let settings: Settings
    @Binding var draft: PoolSettingsDraft
    let isSaving: Bool
    let canApply: Bool
    let saveError: String?
    let apply: () -> Void

    var body: some View {
        Section {
            TextField("Maximum concurrent jobs", text: $draft.capacityInput)
                .disabled(isSaving)
                .accessibilityIdentifier("execution-limit")
            Picker("Idle Simulators", selection: $draft.keepsSimulatorsForever) {
                Text("Remove after an idle period").tag(false)
                Text("Keep indefinitely").tag(true)
            }
            .disabled(isSaving)
            .accessibilityIdentifier("simulator-retention-mode")
            if !draft.keepsSimulatorsForever {
                TextField("Idle retention (minutes)", text: $draft.simulatorIdleRetentionInput)
                    .disabled(isSaving)
                    .accessibilityIdentifier("simulator-idle-retention")
            }
            HStack {
                Spacer()
                Button(isSaving ? "Applying…" : "Apply", action: apply)
                    .disabled(!canApply)
                    .accessibilityIdentifier("apply-pool-configuration")
            }
            if let error = settings.poolError { ErrorText(error) }
            if let saveError { ErrorText(saveError) }
            if let error = settings.configurationCleanupError { ErrorText(error) }
            if let error = settings.simulatorPoolError { ErrorText(error) }
        } header: {
            Text("Xcode Execution")
        } footer: {
            Text("The limit is shared by all repositories, and each repository registers that many runners. Running jobs finish before a lower limit applies. Idle Simulators stay booted for reuse until their retention ends.")
        }
    }
}

/// A Mac's storage folder, in its own window or in a paired Mac's pane for it.
@MainActor
struct StorageSection<Settings: HostSettingsDisplay>: View {
    let settings: Settings
    @Binding var directory: String
    let isSaving: Bool
    let saveError: String?
    let mac: MacReference
    let isRestarting: Bool
    /// Why the Mac refused to restart for a paired Mac, or why it did not confirm that it restarts.
    let restartError: String?
    /// Chooses a folder on this Mac. A paired Mac's pane has no folder panel for another Mac.
    let choose: (() -> Void)?
    let restart: () -> Void
    let save: () -> Void
    @State private var isConfirmingRestart = false

    var body: some View {
        Section {
            TextField("Storage folder", text: $directory, prompt: Text("Not chosen"))
                .accessibilityIdentifier("storage-folder")
                .disabled(!canEdit)
            HStack {
                Spacer()
                if let choose {
                    Button("Choose…", action: choose)
                        .accessibilityIdentifier("choose-storage-folder")
                }
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .accessibilityIdentifier("save-storage-folder")
            }
            .disabled(!canEdit)
            Text(settings.storageMessage).foregroundStyle(.secondary)
            // A host that launchd did not start is restarted by whoever started it.
            if settings.storageChangeIsPending, settings.canRestart || isRestarting || isSaving {
                HStack {
                    Spacer()
                    Button(isRestarting ? "Restarting…" : "Restart to Apply…") { isConfirmingRestart = true }
                        .disabled(isRestarting || isSaving || !settings.canRestart)
                        .accessibilityIdentifier("restart-host")
                }
            }
            if let error = settings.storageError { ErrorText(error) }
            if let saveError { ErrorText(saveError) }
            if let restartError { ErrorText(restartError) }
        } header: {
            Text("Storage")
        } footer: {
            Text("A changed folder is applied before runners start on the next launch. Existing data is copied and its original files are kept. Stop other tools that use these files before restarting the host.")
        }
        .confirmationDialog("Restart XcodeHomeRunner on \(mac.object)?", isPresented: $isConfirmingRestart) {
            Button("Restart", role: .destructive, action: restart)
        } message: {
            Text("\(runningJobs) Restarting stops \(mac.possessive) runner services until the host has started again, with the jobs that they run, and the saved storage folder is applied then.")
        }
    }

    /// The Xcode jobs counted at the last read. The count includes jobs that other tools started in the same
    /// execution pool, which a restart leaves running, and a job can have started since.
    private var runningJobs: String {
        switch settings.poolStatus?.activeJobCount {
        case nil: "The Xcode jobs running on \(mac.object) are unknown."
        case 0?: "No Xcode jobs were running on \(mac.object) at the last read."
        case 1?: "1 Xcode job was running on \(mac.object) at the last read."
        case let count?: "\(count) Xcode jobs were running on \(mac.object) at the last read."
        }
    }

    private var canEdit: Bool { settings.canEditStorage && !isSaving }
}
