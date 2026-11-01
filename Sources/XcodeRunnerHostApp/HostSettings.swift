import Foundation
import Observation
import SwiftUI
import XcodeRunnerHostSupport
import XcodeRunnerKit

enum HostState: String, Sendable {
    case starting = "Starting"
    case preparingStorage = "Preparing storage"
    case waitingForStorage = "Waiting for storage"
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

    init(installation: HostInstallation, github: GitHubHostSettings? = nil) {
        self.installation = installation
        // Reading status leaves an unconfigured pool unchanged.
        self.pool = HostExecutionPool(directory: installation.poolDirectory)
        self.settingsService = HostSettingsService(installation: installation, pool: pool)
        self.github = github ?? GitHubHostSettings(installation: installation, pool: pool)
        do {
            savedStorageDirectory = try installation.requestedStorageDirectory() ?? installation.storage()?.directory
            storageDirectoryInput = savedStorageDirectory?.path(percentEncoded: false) ?? ""
        } catch {
            storageSaveError = "Could not read the saved storage folder: \(error.localizedDescription)"
        }
    }

    var storageMessage: String {
        if hostState == .waitingForStorage {
            return "Runner services start when storage becomes available. Folder changes saved now apply on the next host launch."
        }
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
struct HostMacSettingsView: View {
    @Bindable var model: HostSettingsModel

    var body: some View {
        Form {
            Section {
                if model.runners.isEmpty {
                    Text(model.storageError == nil ? "No runners have opted in to this host." : "Runner services have not started because storage needs attention.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.runners) { runner in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(runner.name, value: runner.state.rawValue)
                        if runner.state == .individualService {
                            Text("This runner uses its individual service. The host does not start another service for it.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let error = runner.configurationError { ErrorText(error) }
                    }
                }
                if let error = model.runnerScanError { ErrorText(error) }
            } header: {
                Text("Runner Services")
            } footer: {
                Text("Processes on this Mac. Overview shows each repository's connection and job counts from GitHub.")
            }
            Section {
                TextField("Maximum concurrent jobs", text: $model.capacityInput)
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("execution-limit")
                Picker("Idle Simulators", selection: $model.keepsSimulatorsForever) {
                    Text("Remove after an idle period").tag(false)
                    Text("Keep indefinitely").tag(true)
                }
                .disabled(model.isSaving)
                .accessibilityIdentifier("simulator-retention-mode")
                if !model.keepsSimulatorsForever {
                    TextField("Idle retention (minutes)", text: $model.simulatorIdleRetentionInput)
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("simulator-idle-retention")
                }
                HStack {
                    Spacer()
                    Button(model.isSaving ? "Applying…" : "Apply") {
                        Task { await model.applyPoolConfiguration() }
                    }
                    .disabled(!model.canApplyPoolConfiguration)
                    .accessibilityIdentifier("apply-pool-configuration")
                }
                if let error = model.poolError { ErrorText(error) }
                if let error = model.saveError { ErrorText(error) }
                if let error = model.configurationCleanupError { ErrorText(error) }
                if let error = model.simulatorPoolError { ErrorText(error) }
            } header: {
                Text("Xcode Execution")
            } footer: {
                Text("The limit is shared by all repositories, and each repository registers that many runners. Running jobs finish before a lower limit applies. Idle Simulators stay booted for reuse until their retention ends.")
            }
            Section {
                TextField("Storage folder", text: $model.storageDirectoryInput, prompt: Text("Not chosen"))
                    .accessibilityIdentifier("storage-folder")
                    .disabled(!model.canEditStorage)
                HStack {
                    Spacer()
                    Button("Choose…") { Task { await model.chooseStorageDirectory() } }
                        .accessibilityIdentifier("choose-storage-folder")
                    Button(model.isSavingStorage ? "Saving…" : "Save") { Task { await model.saveStorageSelection() } }
                        .accessibilityIdentifier("save-storage-folder")
                }
                .disabled(!model.canEditStorage)
                Text(model.storageMessage).foregroundStyle(.secondary)
                if let error = model.storageError { ErrorText(error) }
                if let error = model.storageSaveError { ErrorText(error) }
            } header: {
                Text("Storage")
            } footer: {
                Text("A changed folder is applied before runners start on the next launch. Existing data is copied and its original files are kept. Stop other tools that use these files before restarting the host.")
            }
        }
    }
}
