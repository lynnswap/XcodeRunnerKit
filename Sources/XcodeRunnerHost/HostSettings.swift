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
        do {
            return Self(
                directory: runner.url, name: try runner.registration().agentName ?? runner.name, state: state,
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
    var hostState = HostState.starting
    var runners: [RunnerSettingsRow] = []
    var runnerScanError: String?
    private(set) var poolStatus: HostExecutionPool.Status?
    private(set) var poolError: String?
    private(set) var saveError: String?
    private(set) var isSaving = false
    private(set) var hasLoadedPoolStatus = false
    var capacityInput = String(HostInstallation.defaultMaximumConcurrentJobs)
    private(set) var activeStorage: HostInstallation.Storage?
    private(set) var storageError: String?
    private(set) var storageSaveError: String?
    private(set) var savedStorageDirectory: URL?
    private(set) var isSavingStorage = false
    var storageDirectoryInput = ""

    init(installation: HostInstallation) {
        self.installation = installation
        // Reading status does not initialize the pool. Only Apply or a job can do that.
        self.pool = HostExecutionPool(directory: installation.poolDirectory)
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
            let directory = try await installation.requestStorageDirectory(URL(filePath: storageDirectoryInput))
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
        if poolStatus.activeJobCount > poolStatus.maximumConcurrentJobs {
            return "Existing jobs will finish. New jobs wait until the running count falls below the limit."
        }
        if poolStatus.activeJobCount == poolStatus.maximumConcurrentJobs {
            return "New jobs wait for an available slot."
        }
        return "New jobs can start while slots are available."
    }

    func refreshPoolStatus() async {
        do {
            let previousInput = String(poolStatus?.maximumConcurrentJobs ?? HostInstallation.defaultMaximumConcurrentJobs)
            let status = try await pool.status()
            poolStatus = status
            poolError = nil
            hasLoadedPoolStatus = true
            if capacityInput == previousInput, let status {
                capacityInput = String(status.maximumConcurrentJobs)
            }
        } catch is CancellationError {
            return
        } catch {
            poolStatus = nil
            poolError = "Could not read the execution pool: \(error.localizedDescription)"
            hasLoadedPoolStatus = true
        }
    }

    var canApplyLimit: Bool { hasLoadedPoolStatus && !isSaving && !github.isBusy && hostState != .stopping }

    func applyCapacity() async {
        guard canApplyLimit else { return }
        guard let capacity = Int(capacityInput), capacity > 0 else {
            saveError = "Enter a positive whole number."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await pool.updateMaximumConcurrentJobs(to: capacity)
            do {
                try github.saveSelection()
            } catch {
                saveError = "The execution limit was saved as \(capacity), but the repository selection could not be saved: \(error.localizedDescription)"
                await refreshPoolStatus()
                return
            }
            saveError = nil
            await refreshPoolStatus()
            await github.synchronize()
        } catch {
            saveError = "Could not save the execution limit: \(error.localizedDescription)"
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
                        Text(model.poolStatus.map { String($0.maximumConcurrentJobs) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    HStack {
                        TextField("Maximum concurrent Xcode jobs", text: $model.capacityInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("execution-limit")
                        Button(model.isSaving ? "Applying…" : "Apply") {
                            Task { await model.applyCapacity() }
                        }
                        .disabled(!model.canApplyLimit)
                        .accessibilityIdentifier("apply-execution-limit")
                    }
                    Text(model.admissionMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("This limit is shared across all repositories. Selected repositories receive enough runner registrations to use it. GitHub jobs may wait here after assignment; their in-progress count can be higher than the Xcode execution count.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = model.poolError { errorMessage(error) }
                    if let error = model.saveError { errorMessage(error) }
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
