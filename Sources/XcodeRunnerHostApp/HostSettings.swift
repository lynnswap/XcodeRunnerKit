import AppKit
import Foundation
import Observation
import XcodeRunnerHostSupport
import XcodeRunnerKit

/// What a Mac's host does, by the name that its panes show. A Mac shows the state of a paired Mac that runs a newer
/// version by that name when it does not know the state.
struct HostState: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let starting = Self(rawValue: "Starting")
    static let preparingStorage = Self(rawValue: "Preparing storage")
    static let waitingForStorage = Self(rawValue: "Waiting for storage")
    static let running = Self(rawValue: "Running")
    static let needsAttention = Self(rawValue: "Needs attention")
    static let stopping = Self(rawValue: "Stopping")
}

/// What a runner's service does, by the name that the Mac's pane shows. A Mac shows the state of a runner on a paired
/// Mac that runs a newer version by that name when it does not know the state.
struct RunnerServiceState: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let starting = Self(rawValue: "Starting")
    static let running = Self(rawValue: "Running")
    static let stopped = Self(rawValue: "Stopped")
    static let failed = Self(rawValue: "Needs attention")
    static let individualService = Self(rawValue: "Individual service")
    /// The Mac is paused, and the host stopped the runner's service or did not start it.
    static let paused = Self(rawValue: "Paused")
    /// The Mac is paused, and the runner's service stops after the job that it runs.
    static let finishing = Self(rawValue: "Finishing a job")
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

/// The labels of a Mac's runners, as a person types them and as GitHub compares them.
enum RunnerLabels {
    /// The labels in a list that a person separated with commas.
    static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func text(_ labels: [String]) -> String { labels.joined(separator: ", ") }

    /// The labels in lowercase and once each, because GitHub compares labels without regard to case.
    ///
    /// Throws for a label that a runner cannot be given or that every runner already has.
    static func validated(_ labels: [String]) throws(HostSettingsError) -> [String] {
        var result: [String] = []
        for label in labels.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !result.contains(label) {
            // The runner's setup takes its labels as one list separated by commas.
            guard !label.isEmpty, !label.contains(","), !label.contains(where: \.isNewline) else {
                throw HostSettingsError("A runner label cannot be empty or contain a comma.")
            }
            guard !["self-hosted", "macos", "arm64", "xcode-runnerkit"].contains(label) else {
                throw HostSettingsError("Every runner already has the label \(label).")
            }
            result.append(label)
        }
        return result
    }
}

/// A job limit and Simulator retention being edited, for this Mac or for a Mac paired with it.
struct PoolSettingsDraft: Equatable {
    /// The edited settings. A setting that matches the saved one is `nil`, so Save leaves its saved value as it is.
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

    /// Whether an input differs from the saved settings.
    var isEdited: Bool { capacityInput != String(base.maximumConcurrentJobs) || !shows(base.simulatorRetention) }

    /// Shows the saved settings in every input again, which drops the edits.
    mutating func revert() { reset(to: base) }

    /// Shows the settings that Save saved in every input.
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
    /// Whether the Mac takes no new jobs. Its runners stay registered and appear offline on GitHub.
    var isPaused: Bool { get }
    /// The labels that the Mac's runners get besides `xcode-runnerkit`, so that a workflow can choose the Mac.
    var runnerLabels: [String] { get }
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
    /// The Xcode that the Mac's jobs use when they name none, or `nil` for the Xcode that `xcode-select` names.
    var savedDeveloperDirectory: URL? { get }
    var installedXcodes: [InstalledXcode] { get }
    /// Whether the saved Xcode's folder no longer exists on the Mac, so that jobs that name no Xcode fail.
    var savedXcodeIsMissing: Bool { get }
    var xcodeError: String? { get }
    /// The build service that the Mac's jobs use when they name none. With `nil`, they use the one that their
    /// environment names, or the one in their Xcode.
    var savedBuildService: URL? { get }
    /// Whether no file is at the saved build service's path on the Mac, so that the jobs that use it fail.
    var savedBuildServiceIsMissing: Bool { get }
    var buildServiceError: String? { get }
    var canApplyPoolConfiguration: Bool { get }
    var canEditStorage: Bool { get }
    /// Whether the host can restart itself. A host that launchd did not start cannot.
    var canRestart: Bool { get }
}

extension HostSettingsDisplay {
    /// Whether Save saves every pool setting, because the pool has none saved.
    var isNewPool: Bool { poolStatus == nil && poolError == nil }

    var jobSummary: String {
        guard let status = poolStatus else {
            if !hasLoadedPoolStatus { return "Checking…" }
            return poolError == nil ? "Not configured" : "Unavailable"
        }
        return "\(status.activeJobCount) running · \(status.waitingJobCount) waiting · Limit \(status.configuration.maximumConcurrentJobs)"
    }

    /// Whether the host runs and takes no new jobs, which is not a problem to solve.
    var showsPaused: Bool { isPaused && hostState == .running }

    var admissionMessage: String {
        if showsPaused { return "Runner services stop after the jobs that they run, and no new jobs start." }
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
            return "Runner services start when storage becomes available. Folder changes apply on the next host launch. Finish work using runner storage before restarting."
        }
        if storageChangeIsPending {
            return "Saved for the next host launch. Finish work using runner storage before restarting to apply the saved folder."
        }
        if activeStorageDirectory != nil { return "Runner checkouts, build results, and the shared compiler cache use this folder." }
        return "Choose one folder for runner checkouts, build results, and the shared compiler cache."
    }
}

/// What a Mac sends the Macs paired with it about its status and settings.
struct HostSettingsReport: Codable, Equatable, Sendable {
    /// Missing on hosts from before working-tree capacity reporting.
    let runnerSlots: RunnerSlots?
    let resourceSample: RunnerMetricSample?
    /// Older runners and relays only pass the latest sample in their settings reports.
    let supportsActivityHistory: Bool?
    let hostState: HostState
    let isPaused: Bool
    let runnerLabels: [String]
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
    let savedDeveloperDirectory: URL?
    let installedXcodes: [InstalledXcode]
    let savedXcodeIsMissing: Bool
    let xcodeError: String?
    let savedBuildService: URL?
    /// `nil` in the report of a Mac that runs a version without the setting.
    private let buildServiceIsMissing: Bool?
    var savedBuildServiceIsMissing: Bool { buildServiceIsMissing ?? false }
    /// Whether the Mac reports its build service. One that runs a version without the setting can have one saved.
    var reportsBuildService: Bool { buildServiceIsMissing != nil }
    let buildServiceError: String?
    let jobOptions: HostJobOptions?
    let jobOptionsReadError: String?
    let canApplyPoolConfiguration: Bool
    let canEditStorage: Bool
    let canRestart: Bool

    @MainActor init(_ settings: HostSettingsModel) {
        runnerSlots = settings.runnerSlots
        resourceSample = settings.resourceHistory.samples.last
        supportsActivityHistory = true
        hostState = settings.hostState
        isPaused = settings.isPaused
        runnerLabels = settings.runnerLabels
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
        savedDeveloperDirectory = settings.savedDeveloperDirectory
        installedXcodes = settings.installedXcodes
        savedXcodeIsMissing = settings.savedXcodeIsMissing
        xcodeError = settings.xcodeError
        savedBuildService = settings.savedBuildService
        buildServiceIsMissing = settings.savedBuildServiceIsMissing
        buildServiceError = settings.buildServiceError
        jobOptions = settings.jobOptions
        jobOptionsReadError = settings.jobOptionsReadError
        canApplyPoolConfiguration = settings.canApplyPoolConfiguration
        canEditStorage = settings.canEditStorage
        canRestart = settings.canRestart
    }
}

// Conforming in the type's declaration would isolate the report to the main actor, where network connections do not
// encode and decode it.
extension HostSettingsReport: HostSettingsDisplay {}

/// One Mac's save. A new window can read the same pending settings while the writes finish in order.
@MainActor @Observable
final class SettingsSave<Field: Hashable> {
    private(set) var pending: Set<Field> = []
    private var total = 0

    var progress: (completed: Int, total: Int)? {
        pending.isEmpty ? nil : (total - pending.count, total)
    }

    func start(_ fields: [Field], apply: @escaping @MainActor (Field) async -> Void) {
        guard pending.isEmpty, !fields.isEmpty else { return }
        pending = Set(fields)
        total = fields.count
        Task {
            for field in fields {
                await apply(field)
                pending.remove(field)
            }
        }
    }
}

enum RunnerSetting {
    case pool, runnerLabels, xcode, buildService, storage
}

@MainActor @Observable
final class HostSettingsDraft {
    enum Field { case jobOptions, repositories }

    let save = SettingsSave<Field>()
    var jobOptions: HostJobOptions.Edits = [:]
    var jobOptionsError: String?

    func saveJobOptions(using write: (HostJobOptions.Edits) async throws -> Void) async {
        let edits = jobOptions
        do {
            try await write(edits)
            if jobOptions == edits { jobOptions = [:] }
            jobOptionsError = nil
        } catch { jobOptionsError = error.localizedDescription }
    }
}

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
    @ObservationIgnored private(set) lazy var managedMacsRelay = ManagedMacsRelay(host: self)
    let settingsService: HostSettingsService
    /// Runs the builds and tests that dashboards send to this Mac.
    let operations: RemoteOperations
    private(set) var resourceHistory = RunnerMetricHistory()
    @ObservationIgnored private var resourceSampler = RunnerMetricSampler()

    func sampleResources() { resourceHistory.append(resourceSampler.sample()) }

    var hostState = HostState.starting
    private(set) var isPaused: Bool
    private(set) var pauseError: String?
    private(set) var runnerLabels: [String] = []
    /// The labels being edited, separated by commas.
    var runnerLabelsInput = ""
    private(set) var isSavingRunnerLabels = false
    private(set) var runnerLabelsError: String?
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
    let hostDraft = HostSettingsDraft()
    let runnerSave = SettingsSave<RunnerSetting>()
    private(set) var activeStorageDirectory: URL?
    private(set) var storageError: String?
    private(set) var storageSaveError: String?
    private(set) var savedStorageDirectory: URL?
    private(set) var isSavingStorage = false
    var storageDirectoryInput = ""
    private(set) var savedDeveloperDirectory: URL?
    private(set) var installedXcodes: [InstalledXcode] = []
    private(set) var savedXcodeIsMissing = false
    private(set) var xcodeError: String?
    private(set) var xcodeSaveError: String?
    private(set) var isSavingXcode = false
    /// The selected Xcode's `Contents/Developer` directory, or an empty string for the system selection.
    var xcodeSelectionInput = ""
    private(set) var savedBuildService: URL?
    private(set) var savedBuildServiceIsMissing = false
    private(set) var buildServiceError: String?
    private(set) var buildServiceSaveError: String?
    private(set) var isSavingBuildService = false
    /// The path of the build service's executable, or an empty string to save none.
    var buildServiceInput = ""
    private(set) var jobOptions: HostJobOptions?
    private(set) var jobOptionsReadError: String?

    /// A pairing change immediately selects the new owner's defaults, even on read-only storage.
    func refreshJobOptions() {
        do { _ = try optionsForJobs() }
        catch {
            jobOptions = nil
            jobOptionsReadError = error.localizedDescription
        }
    }

    func optionsForJobs() throws -> HostJobOptions {
        let options = try installation.jobOptionsRecord().options(managedBy: management.manager?.id)
        jobOptions = options
        jobOptionsReadError = nil
        return options
    }

    func saveJobOptions(_ edits: HostJobOptions.Edits) throws {
        guard management.manager == nil else { throw HostSettingsError("Edit job defaults on the managing host.") }
        var record = try installation.jobOptionsRecord()
        record.manager = nil
        record.inherited = HostJobOptions()
        for (kind, entries) in edits {
            record.local[kind] = entries
            _ = try record.local.values(for: kind)
        }
        try installation.saveJobOptionsRecord(record)
        jobOptions = record.local
        jobOptionsReadError = nil
    }

    func applyJobOptions(_ options: HostJobOptions, from manager: UUID) throws {
        guard management.manager?.id == manager else { throw HostSettingsError("Only the managing host can supply job defaults.") }
        var record = try installation.jobOptionsRecord()
        record.manager = manager
        record.inherited = options
        try installation.saveJobOptionsRecord(record)
        jobOptions = options
        jobOptionsReadError = nil
    }

    /// The installed Xcodes are listed again after this long, because listing them reads every Xcode's version.
    private static let xcodeListLifetime = Duration.seconds(30)
    private var xcodesListedAt: ContinuousClock.Instant?
    /// Stops the host and has launchd start it again. `nil` for a host that launchd did not start.
    var restartHost: (@MainActor () -> Void)?
    /// Whether this Mac accepted a paired Mac's request to restart. It then takes no other change, whatever state the
    /// host reaches before it stops.
    private var hasAcceptedRestart = false

    /// - Parameters:
    ///   - installedXcodes: Lists the Xcode apps on this Mac. Tests pass a list in place of Launch Services.
    ///   - operationTool: The command-line tool that runs a dashboard's build or test. Tests pass a script in place
    ///     of the app's `xcode-runner`.
    init(
        installation: HostInstallation, github: GitHubHostSettings? = nil,
        management: HostManagement? = nil, managedMacs: PairedMacs? = nil,
        installedXcodes: @escaping @Sendable () -> [InstalledXcode] = InstalledXcode.installed,
        operationTool: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/xcode-runner")
    ) {
        self.installation = installation
        self.isPaused = installation.isPaused()
        self.operations = RemoteOperations(installation: installation, tool: operationTool)
        // Reading status leaves an unconfigured pool unchanged.
        self.pool = HostExecutionPool(directory: installation.poolDirectory)
        self.settingsService = HostSettingsService(installation: installation, pool: pool, installedXcodes: installedXcodes)
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
        refreshJobOptions()
        refreshXcodes()
        refreshBuildService()
        do {
            runnerLabels = try installation.runnerLabels()
            runnerLabelsInput = RunnerLabels.text(runnerLabels)
        } catch {
            runnerLabelsError = "Could not read the runner labels: \(error.localizedDescription)"
        }
        // The Macs paired with this Mac read and change its settings through the owner of this Mac's window.
        self.management.settings = self
        self.managedMacs.jobOptionsOwner = self
        self.github.pairedMacs = self.managedMacs
        self.github.management = self.management
    }

    func storageDidBecomeAvailable(_ storage: HostInstallation.Storage) {
        activeStorageDirectory = storage.directory
        operations.storage = storage
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
    var canEditStorage: Bool { !isSavingStorage && hostState != .stopping && !hasAcceptedRestart }

    /// A restart waits for a save in progress, whose folder or limit the next launch would otherwise not have.
    var canRestart: Bool {
        restartHost != nil && hostState != .stopping && !hasAcceptedRestart && !isSaving && !isSavingStorage
    }

    /// Restarts the host, which applies a saved storage folder. Runner services stop until it has started again.
    func restart() {
        guard canRestart else { return }
        restartHost?()
    }

    /// Saves the edited labels from this Mac's window, and puts them on this Mac's runners when this Mac registers
    /// them itself.
    func saveRunnerLabelsInput() async {
        guard !isSavingRunnerLabels else { return }
        isSavingRunnerLabels = true
        defer { isSavingRunnerLabels = false }
        do {
            let previous = runnerLabels
            try saveRunnerLabels(RunnerLabels.parse(runnerLabelsInput))
            runnerLabelsError = nil
            runnerLabelsInput = RunnerLabels.text(runnerLabels)
            if runnerLabels != previous { await github.synchronize() }
        } catch {
            runnerLabelsError = error.localizedDescription
        }
    }

    /// Saves the labels for this Mac's runners, from this Mac's window or from a Mac paired with it.
    private func saveRunnerLabels(_ labels: [String]) throws(HostSettingsError) {
        let labels = try RunnerLabels.validated(labels)
        // A synchronization that already read the list would leave the runners with the earlier one.
        guard hostState != .stopping, !hasAcceptedRestart, !github.isBusy else {
            throw HostSettingsError("\(HostPane.macName) cannot save runner labels now. Try again in a moment.")
        }
        let shown = RunnerLabels.text(runnerLabels)
        do {
            try installation.saveRunnerLabels(labels)
        } catch {
            throw HostSettingsError("Could not save the runner labels: \(error.localizedDescription)")
        }
        runnerLabels = labels
        if runnerLabelsInput == shown { runnerLabelsInput = RunnerLabels.text(labels) }
    }

    /// Reads the record again, which can change outside this window as the saved storage folder and Xcode can. The
    /// scan of the runner services calls this, because reading the pool's status can wait for another process.
    func refreshPause() { isPaused = installation.isPaused() }

    /// Pauses or resumes this Mac from its own window.
    func setPaused(_ isPaused: Bool) {
        do {
            try savePaused(isPaused)
            pauseError = nil
        } catch {
            pauseError = error.localizedDescription
        }
    }

    /// Saves whether this Mac takes new jobs, from this Mac's window or from a Mac paired with it. The host stops
    /// and starts its runner services at its next scan of them.
    private func savePaused(_ isPaused: Bool) throws(HostSettingsError) {
        guard hostState != .stopping, !hasAcceptedRestart else {
            throw HostSettingsError("\(HostPane.macName) cannot \(isPaused ? "pause" : "resume") now. Try again in a moment.")
        }
        do {
            try installation.savePaused(isPaused)
            self.isPaused = isPaused
        } catch {
            throw HostSettingsError("Could not \(isPaused ? "pause" : "resume") \(HostPane.macName): \(error.localizedDescription)")
        }
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

    func chooseBuildService() async {
        let panel = NSOpenPanel()
        panel.title = "Choose Build Service"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // The executable is inside a bundle.
        panel.treatsFilePackagesAsDirectories = true
        let response: NSApplication.ModalResponse
        if let window = NSApplication.shared.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        if response == .OK, let executable = panel.url {
            buildServiceInput = executable.path(percentEncoded: false)
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

    /// Reads the saved Xcode, which the CLI and MCP can change, and lists the installed ones when the list is old.
    private func refreshXcodes() {
        let previousInput = savedDeveloperDirectory?.path(percentEncoded: false) ?? ""
        do {
            savedDeveloperDirectory = try installation.developerDirectory()
            xcodeError = nil
            if xcodeSelectionInput == previousInput {
                xcodeSelectionInput = savedDeveloperDirectory?.path(percentEncoded: false) ?? ""
            }
        } catch {
            xcodeError = "Could not read the saved Xcode: \(error.localizedDescription)"
        }
        // The saved Xcode can be one that is not listed, such as a path through a symbolic link.
        savedXcodeIsMissing = savedDeveloperDirectory.map {
            !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        } ?? false
        if let xcodesListedAt, xcodesListedAt.duration(to: .now) < Self.xcodeListLifetime { return }
        installedXcodes = settingsService.installedXcodes()
        xcodesListedAt = .now
    }

    func saveXcodeSelection() async {
        guard !isSavingXcode else { return }
        do {
            try saveDeveloperDirectory(xcodeSelectionInput.isEmpty ? nil : xcodeSelectionInput)
            xcodeSaveError = nil
        } catch {
            xcodeSaveError = error.localizedDescription
        }
    }

    /// Saves the Xcode for this Mac's jobs from this Mac's window or from a Mac paired with it.
    private func saveDeveloperDirectory(_ path: String?) throws(HostSettingsError) {
        if let path, !path.hasPrefix("/") { throw HostSettingsError("Enter an absolute path to an Xcode's Contents/Developer folder.") }
        let previous = savedDeveloperDirectory?.path(percentEncoded: false) ?? ""
        isSavingXcode = true
        defer { isSavingXcode = false }
        do {
            savedDeveloperDirectory = try settingsService.saveDeveloperDirectory(path.map { URL(filePath: $0) })
            if xcodeSelectionInput == previous { xcodeSelectionInput = savedDeveloperDirectory?.path(percentEncoded: false) ?? "" }
            refreshXcodes()
        } catch {
            throw HostSettingsError("Could not save the Xcode: \(error.localizedDescription)")
        }
    }

    /// Reads the saved build service, which the CLI and MCP can change.
    private func refreshBuildService() {
        let previousInput = savedBuildService?.path(percentEncoded: false) ?? ""
        do {
            savedBuildService = try installation.buildServiceExecutableURL()
            buildServiceError = nil
            if buildServiceInput == previousInput { buildServiceInput = savedBuildService?.path(percentEncoded: false) ?? "" }
        } catch {
            // The unread path is not shown, so only saving another one replaces it.
            buildServiceError = "Could not read the saved build service: \(error.localizedDescription) Save a path to replace it."
        }
        savedBuildServiceIsMissing = savedBuildService.map {
            !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        } ?? false
    }

    func saveBuildServiceSelection() async {
        guard !isSavingBuildService else { return }
        do {
            try saveBuildService(buildServiceInput.isEmpty ? nil : buildServiceInput)
            // The saved path is the entered one without its `.` and `..` components.
            buildServiceInput = savedBuildService?.path(percentEncoded: false) ?? ""
            buildServiceSaveError = nil
        } catch {
            buildServiceSaveError = error.localizedDescription
        }
    }

    /// Saves the build service for this Mac's jobs from this Mac's window or from a Mac paired with it.
    private func saveBuildService(_ path: String?) throws(HostSettingsError) {
        if let path, !path.hasPrefix("/") { throw HostSettingsError("Enter an absolute path to a build service's executable.") }
        let previous = savedBuildService?.path(percentEncoded: false) ?? ""
        isSavingBuildService = true
        defer { isSavingBuildService = false }
        do {
            savedBuildService = try settingsService.saveBuildServiceExecutableURL(path.map { URL(filePath: $0) })
            if buildServiceInput == previous { buildServiceInput = savedBuildService?.path(percentEncoded: false) ?? "" }
            refreshBuildService()
        } catch {
            throw HostSettingsError("Could not save the build service: \(error.localizedDescription)")
        }
    }

    func refreshPoolStatus() async {
        if jobOptionsReadError != nil { refreshJobOptions() }
        refreshStorageSelection()
        refreshXcodes()
        refreshBuildService()
        do {
            let status: HostExecutionPool.Status?
            let observedSample = slotSampleID
            do {
                status = try await pool.status(waitForLock: false)
            } catch let error as POSIXError where error.code == .EWOULDBLOCK {
                // Invalidate a known slot count immediately, keeping any reported storage failure until it is checked.
                if observedSample == slotSampleID, sampledSlots.state == "available" || sampledSlots.state == "busy" {
                    sampledSlots = .contended
                }
                startRunnerSlotSample()
                status = try await pool.status()
            }
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
        startRunnerSlotSample()
    }

    /// Inventory samples use a nonblocking pool read. Settings saves and runner registration use
    /// the waiting read above and never consume a partial or contended inventory sample.
    private var sampledSlots = RunnerSlots(state: "unknown", available: nil, reason: "No runner slot report.")
    @ObservationIgnored private var slotSampleID = UUID()
    @ObservationIgnored private var slotRead: Task<Void, Never>?
    @ObservationIgnored private var slotReaders: [UUID: AsyncStream<RunnerSlots>.Continuation] = [:]

    var runnerSlots: RunnerSlots { sampledSlots.forHost(self) }

    private func readRunnerStorageError() async -> String? {
        guard let storage = operations.storage else { return "Storage unavailable." }
        do {
            try await RemoteOperations.requireStorage(storage)
            return nil
        } catch { return error.localizedDescription }
    }

    /// A live reader can leave a stalled volume probe without changing anyone else's observation.
    func readRunnerSlots() async -> RunnerSlots {
        let id = UUID()
        let (events, continuation) = AsyncStream<RunnerSlots>.makeStream()
        slotReaders[id] = continuation
        defer { slotReaders[id] = nil }
        startRunnerSlotSample()
        do {
            let sample = try await HostLink.within(HostLink.requestTimeout + HostLink.requestTimeout / 2) {
                var iterator = events.makeAsyncIterator()
                guard let sample = await iterator.next() else { throw CancellationError() }
                return sample
            }
            return sample.forHost(self)
        } catch {
            return RunnerSlots(state: "unknown", available: nil, reason: error.localizedDescription).forHost(self)
        }
    }

    private func startRunnerSlotSample() {
        guard slotRead == nil else { return }
        slotRead = Task {
            let storageError = await readRunnerStorageError()
            do {
                let status = try await pool.status(waitForLock: false)
                sampledSlots = RunnerSlots(pool: status, poolError: nil, storageError: storageError)
            } catch {
                let reason = (error as? POSIXError)?.code == .EWOULDBLOCK ? RunnerSlots.contended.reason : error.localizedDescription
                sampledSlots = RunnerSlots(pool: nil, poolError: reason, storageError: storageError)
            }
            slotSampleID = UUID()
            slotRead = nil
            for reader in slotReaders.values {
                reader.yield(sampledSlots)
                reader.finish()
            }
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

    var canApplyPoolConfiguration: Bool {
        hasLoadedPoolStatus && !isSaving && !github.isBusy && hostState != .stopping && !hasAcceptedRestart
    }

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
            case .saveXcode(let developerDirectory): try saveDeveloperDirectory(developerDirectory)
            case .saveBuildService(let path): try saveBuildService(path)
            case .saveJobOptions(let options):
                try saveJobOptions(options)
                await managedMacs.distributeJobOptions()
            case .setPaused(let isPaused): try savePaused(isPaused)
            case .saveRunnerLabels(let labels): try saveRunnerLabels(labels)
            case .restart: try acceptRestart()
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

    /// Takes a paired Mac's request to restart. From here on this Mac takes no other change, so that none starts
    /// between the reply and the restart, which `finish(_:answeredWith:registersRunners:)` starts.
    private func acceptRestart() throws(HostSettingsError) {
        guard restartHost != nil else {
            throw HostSettingsError("\(HostPane.macName) cannot restart XcodeHomeRunner by itself. Restart it on that Mac.")
        }
        // The pane that asked may show settings from before a save started here.
        guard canRestart else {
            throw HostSettingsError("\(HostPane.macName) cannot restart now. Try again in a moment.")
        }
        hasAcceptedRestart = true
    }

    /// Restarts the host once the paired Mac that asked has the reply.
    /// Does what follows a settings request that this Mac answered, once the reply is delivered or its connection is
    /// gone. The change is saved by then, so none of this depends on the reply arriving.
    ///
    /// - Parameter registersRunners: Whether this Mac registers its runners for a changed job limit or changed
    ///   labels, as it does after its own change. A managing host registers them itself.
    func finish(_ request: HostSettingsRequest, answeredWith answer: HostLinkReply, registersRunners: Bool) async {
        guard case .settings = answer else { return }
        let registrationsChanged = switch request {
        case .configurePool(let changes): changes.maximumConcurrentJobs != nil
        case .saveRunnerLabels: true
        default: false
        }
        if registersRunners, registrationsChanged { await github.synchronize() }
        if case .restart = request { restartHost?() }
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
