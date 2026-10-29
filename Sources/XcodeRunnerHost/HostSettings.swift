import Foundation
import Observation
import SwiftUI
import XcodeRunnerHostSupport
import XcodeRunnerKit

enum HostState: String, Sendable {
    case starting = "Starting"
    case preparingStorage = "Preparing storage"
    case running = "Running"
    case needsAttention = "Needs attention"
    case stopping = "Stopping"
}

enum RunnerServiceState: String, Sendable {
    case starting = "Starting"
    case running = "Running"
    case stopped = "Stopped"
    case failed = "Needs attention"
    case individualService = "Individual service"
}

struct RunnerSettingsRow: Identifiable, Sendable {
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

@MainActor @Observable
final class HostSettingsModel {
    let installation: HostInstallation
    let pool: HostExecutionPool
    let github: GitHubHostSettings
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
    private var poolDraftBase = HostExecutionPool.Configuration(maximumConcurrentJobs: HostInstallation.defaultMaximumConcurrentJobs)
    var capacityInput = String(HostInstallation.defaultMaximumConcurrentJobs)
    var keepsSimulatorsForever = false
    var simulatorIdleRetentionInput = "20"
    private(set) var activeStorage: HostInstallation.Storage?
    private(set) var storageError: String?
    private(set) var storageSaveError: String?
    private(set) var savedStorageDirectory: URL?
    private(set) var isSavingStorage = false
    var storageDirectoryInput = ""

    init(installation: HostInstallation) {
        self.installation = installation
        // Reading status leaves an unconfigured pool unchanged.
        self.pool = HostExecutionPool(directory: installation.poolDirectory)
        self.settingsService = HostSettingsService(installation: installation, pool: pool)
        self.github = GitHubHostSettings(installation: installation, pool: pool)
        do {
            savedStorageDirectory = try installation.requestedStorageDirectory() ?? installation.storage()?.directory
            storageDirectoryInput = savedStorageDirectory?.path(percentEncoded: false) ?? ""
        } catch {
            storageSaveError = "Could not read the saved storage folder: \(error.localizedDescription)"
        }
    }

    var storageMessage: String {
        if let savedStorageDirectory, savedStorageDirectory != activeStorage?.directory {
            if activeStorage == nil { return "Saved for the next host launch." }
            return "Saved for the next host launch. Running jobs continue using their current storage."
        }
        if activeStorage != nil { return "Runner checkouts, build results, and the shared compiler cache use this folder." }
        return "Choose one folder for runner checkouts, build results, and the shared compiler cache."
    }

    func storageDidBecomeAvailable(_ storage: HostInstallation.Storage) {
        activeStorage = storage
        github.storageIsReady = true
        storageError = nil
        if savedStorageDirectory == nil {
            savedStorageDirectory = storage.directory
            storageDirectoryInput = storage.directory.path(percentEncoded: false)
        }
    }

    func storagePreparationFailed(_ error: any Error) {
        github.storageIsReady = false
        storageError = "Could not prepare storage: \(error.localizedDescription)"
        hostState = .needsAttention
    }

    /// Whether the storage folder can be edited and saved. It stays available while the host needs attention.
    var canEditStorage: Bool { !isSavingStorage && hostState != .stopping }

    func saveStorageSelection() async {
        guard canEditStorage else { return }
        guard storageDirectoryInput.hasPrefix("/") else {
            storageSaveError = "Enter an absolute folder path or choose a folder."
            return
        }
        isSavingStorage = true
        defer { isSavingStorage = false }
        do {
            let directory = try await settingsService.requestStorageDirectory(URL(filePath: storageDirectoryInput))
            savedStorageDirectory = directory
            storageDirectoryInput = directory.path(percentEncoded: false)
            storageSaveError = nil
        } catch {
            storageSaveError = "Could not save the storage folder: \(error.localizedDescription)"
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
        let previousCapacity = String(poolDraftBase.maximumConcurrentJobs)
        let capacityDraft = capacityInput
        let retentionDraft = (keepsSimulatorsForever, simulatorIdleRetentionInput)
        let previousRetention = poolDraftBase.simulatorRetention
        let retentionWasUnedited: Bool
        switch previousRetention {
        case .forever: retentionWasUnedited = keepsSimulatorsForever
        case .idleTimeout(let minutes):
            retentionWasUnedited = !keepsSimulatorsForever && simulatorIdleRetentionInput == String(minutes)
        }
        do {
            let status = try await pool.status()
            poolStatus = status
            poolError = nil
            hasLoadedPoolStatus = true
            poolDraftBase = status?.configuration ?? .init(maximumConcurrentJobs: HostInstallation.defaultMaximumConcurrentJobs)
            if capacityDraft == previousCapacity, capacityInput == capacityDraft, let status {
                capacityInput = String(status.configuration.maximumConcurrentJobs)
            }
            if retentionWasUnedited,
               keepsSimulatorsForever == retentionDraft.0, simulatorIdleRetentionInput == retentionDraft.1 {
                updateRetentionDraft(from: savedSimulatorRetention)
            }
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

    private func updateRetentionDraft(from retention: HostExecutionPool.SimulatorRetention) {
        switch retention {
        case .forever: keepsSimulatorsForever = true
        case .idleTimeout(let minutes):
            keepsSimulatorsForever = false
            simulatorIdleRetentionInput = String(minutes)
        }
    }

    var canApplyPoolConfiguration: Bool { hasLoadedPoolStatus && !isSaving && !github.isBusy && hostState != .stopping }

    func applyPoolConfiguration() async {
        guard canApplyPoolConfiguration else { return }
        guard let capacity = Int(capacityInput), capacity > 0 else {
            saveError = "Enter a positive whole number of concurrent jobs."
            return
        }
        let retention: HostExecutionPool.SimulatorRetention
        if keepsSimulatorsForever {
            retention = .forever
        } else {
            guard let minutes = Int(simulatorIdleRetentionInput), minutes > 0 else {
                saveError = "Enter a positive whole number of idle minutes."
                return
            }
            retention = .idleTimeout(minutes: minutes)
        }
        let previousCapacity = poolStatus?.configuration.maximumConcurrentJobs
        let isNewPool = poolStatus == nil && poolError == nil
        let maximumPatch = isNewPool || capacity != poolDraftBase.maximumConcurrentJobs ? capacity : nil
        let retentionPatch = isNewPool || retention != poolDraftBase.simulatorRetention ? retention : nil
        isSaving = true
        defer { isSaving = false }
        do {
            let saved: HostExecutionPool.Configuration
            do {
                saved = try await settingsService.configurePool(maximumConcurrentJobs: maximumPatch, simulatorRetention: retentionPatch)
                configurationCleanupError = nil
            } catch let failure as HostExecutionPool.ConfigurationCleanupFailure {
                saved = failure.savedConfiguration
                configurationCleanupError = failure.localizedDescription
            }
            saveError = nil
            capacityInput = String(saved.maximumConcurrentJobs)
            updateRetentionDraft(from: saved.simulatorRetention)
            poolDraftBase = saved
            await refreshPoolStatus()
            if previousCapacity != saved.maximumConcurrentJobs { await github.synchronize() }
        } catch {
            saveError = "Could not save the execution pool settings: \(error.localizedDescription)"
        }
    }
}

@MainActor
struct HostSettingsView: View {
    @Bindable var model: HostSettingsModel

    var body: some View {
        ScrollView {
            Form {
                GitHubSettingsView(model: model.github)
                    .disabled(model.isSaving)
                Section("Storage") {
                    TextField("Storage folder", text: $model.storageDirectoryInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("storage-folder")
                        .disabled(!model.canEditStorage)
                    HStack {
                        Button("Choose…") { Task { await model.chooseStorageDirectory() } }
                            .accessibilityIdentifier("choose-storage-folder")
                        Button(model.isSavingStorage ? "Saving…" : "Save") { Task { await model.saveStorageSelection() } }
                            .accessibilityIdentifier("save-storage-folder")
                    }
                    .disabled(!model.canEditStorage)
                    Text(model.storageMessage).font(.callout).foregroundStyle(.secondary)
                    Text("A changed folder is applied before runners start on the next launch. Existing data is copied and its original files are kept. Stop other tools that use these files before restarting the host.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = model.storageError { errorMessage(error) }
                    if let error = model.storageSaveError { errorMessage(error) }
                }
                Section("Xcode Execution") {
                    LabeledContent("Running jobs") {
                        Text(model.poolStatus.map { String($0.activeJobCount) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    LabeledContent("Waiting jobs (High)") {
                        Text(model.poolStatus.map { String($0.waitingJobCounts.high) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    LabeledContent("Waiting jobs (Medium)") {
                        Text(model.poolStatus.map { String($0.waitingJobCounts.medium) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    LabeledContent("Waiting jobs (Low)") {
                        Text(model.poolStatus.map { String($0.waitingJobCounts.low) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    LabeledContent("Current limit") {
                        Text(model.poolStatus.map { String($0.configuration.maximumConcurrentJobs) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    TextField("Maximum concurrent Xcode jobs", text: $model.capacityInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("execution-limit")
                    LabeledContent("Current Simulator retention", value: model.simulatorRetentionDescription)
                    Picker("Idle Simulators", selection: $model.keepsSimulatorsForever) {
                        Text("Remove after an idle period").tag(false)
                        Text("Keep indefinitely").tag(true)
                    }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("simulator-retention-mode")
                    if !model.keepsSimulatorsForever {
                        TextField("Idle retention (minutes)", text: $model.simulatorIdleRetentionInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isSaving)
                            .accessibilityIdentifier("simulator-idle-retention")
                    }
                    Button(model.isSaving ? "Applying…" : "Apply") {
                        Task { await model.applyPoolConfiguration() }
                    }
                    .disabled(!model.canApplyPoolConfiguration)
                    .accessibilityIdentifier("apply-pool-configuration")
                    Text(model.admissionMessage)
                        .font(.callout).foregroundStyle(.secondary)
                    Text("This limit is shared across all repositories. Changes apply to new jobs; running jobs finish first. Runner registrations are synchronized to the saved limit.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Idle Simulators stay booted for reuse. Keep indefinitely disables expiry; the pool still removes excess or unhealthy devices. With an idle period, each return starts a new retention period.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = model.poolError { errorMessage(error) }
                    if let error = model.saveError { errorMessage(error) }
                    if let error = model.configurationCleanupError { errorMessage(error) }
                    if let error = model.simulatorPoolError { errorMessage(error) }
                }
                Section("Runner Services") {
                    LabeledContent("Host", value: model.hostState.rawValue)
                    if model.runners.isEmpty {
                        Text(model.storageError == nil ? "No runners have opted in to this host." : "Runner services have not started because storage needs attention.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.runners) { runner in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(runner.name).font(.headline)
                                Spacer()
                                Text(runner.state.rawValue).foregroundStyle(.secondary)
                            }
                            if runner.state == .individualService {
                                Text("This runner uses its individual service. The host does not start another service for it.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let error = runner.configurationError { errorMessage(error) }
                        }
                        .padding(.vertical, 4)
                    }
                    Text("Service status describes local processes. Check GitHub for connection and job status.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = model.runnerScanError { errorMessage(error) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 540, minHeight: 420)
    }

    private var unavailablePoolValue: String {
        if !model.hasLoadedPoolStatus { return "Checking…" }
        return model.poolError == nil ? "Not configured" : "Unavailable"
    }

    private func errorMessage(_ message: String) -> some View {
        Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
    }
}
