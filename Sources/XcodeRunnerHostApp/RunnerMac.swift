import Foundation
import XcodeRunnerHostSupport

/// The Mac whose runner folders a provisioner reads and changes: this Mac, or a Mac that this host manages.
protocol RunnerMac: Sendable {
    /// The host name that names the Mac's new runners.
    func hostName() async throws -> String
    func runners() async throws -> RunnerInventory
    /// Downloads the official runner archive to the Mac, or reuses a verified earlier download.
    ///
    /// - Returns: The archive's location on the Mac.
    func prepareArchive(_ download: GitHubRunnerDownload) async throws -> URL
    func install(_ request: RunnerProvisioner.InstallationRequest) async throws
    func markUnregistering(_ runner: String, from repositoryID: Int) async throws -> Bool
    func retainRegistration(_ runner: String) async throws
    func markRemoved(_ runner: String) async throws
    /// Records the labels of the Mac's lists that its runners have, after the host put them on the runners.
    func markLabelsApplied(_ labels: [String]) async throws
}

/// Owned by the executing host. Admission and the decision to remove a registration run on the same actor.
@MainActor final class GitHubJobReservations {
    private var runners: Set<URL> = []

    nonisolated init() {}

    func contains(_ directory: URL) -> Bool { runners.contains(directory) }
    func begin(_ directory: RunnerDirectory, installation: HostInstallation) throws {
        guard !installation.isPaused(), try directory.isHosted(), try !directory.isRemoved(),
              try directory.unregisteringRepository() == nil else { throw CancellationError() }
        runners.insert(directory.url)
    }
    func finish(_ directory: URL) { runners.remove(directory) }
}

/// A Mac's runner folders, read at once so that a Mac can send them to its managing host.
struct RunnerInventory: Codable, Sendable {
    /// An entry in the runners root whose type could not be read.
    struct UnreadableEntry: Codable, Sendable {
        let registrationFile: String
        let reason: String
    }

    let folders: [RunnerFolder]
    let unreadable: [UnreadableEntry]
    /// Every entry name in the runners root, so that a new runner does not take one.
    let entryNames: Set<String>
    /// The labels that the Mac's runners get besides `xcode-runnerkit`.
    let labels: [String]
    /// The labels of the Mac's earlier lists that its runners can still have.
    let appliedLabels: [String]

    func folder(named name: String) -> RunnerFolder? { folders.first { $0.name == name } }
}

/// A runner folder's markers and registration settings. Each accessor throws the error that reading its file threw,
/// as `RunnerDirectory` does.
struct RunnerFolder: Codable, Sendable {
    /// The registration fields that the provisioner uses. Other fields stay unchecked.
    struct Registration: Codable, Sendable {
        let agentId: Int
        let agentName: String?
        let gitHubUrl: String?
        let serverUrl: String?
        var workFolder: String?

        var repositoryFullName: String? {
            guard let value = gitHubUrl ?? serverUrl, let url = URL(string: value),
                  url.host()?.lowercased() == "github.com" else { return nil }
            let name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return name.split(separator: "/").count == 2 ? name : nil
        }
    }

    /// A file's contents, or the description of the error that reading it threw.
    private enum Reading<Value: Codable & Sendable>: Codable, Sendable {
        case value(Value)
        case failure(String)

        init(_ read: () throws -> Value) {
            do { self = .value(try read()) } catch { self = .failure(error.localizedDescription) }
        }

        func get() throws -> Value {
            switch self {
            case .value(let value): value
            case .failure(let description): throw ProvisioningError(description)
            }
        }
    }

    let name: String
    let path: String
    // Each marker keeps its own result, so a file that a decision does not need cannot hide the runner.
    private let hosted: Reading<Bool>
    private let individualService: Reading<Bool>
    private let registered: Reading<Bool>
    private let removed: Reading<Bool>
    private let unregistering: Reading<String?>
    private let installationOwner: Reading<String?>
    /// `nil` when the folder has no registration settings or their presence could not be read.
    private let registrationSettings: Reading<Registration>?
    private let jobName: Reading<String?>?

    init(reading directory: RunnerDirectory) {
        jobName = Reading(directory.jobRunnerName)
        name = directory.name
        path = directory.url.path(percentEncoded: false)
        hosted = Reading(directory.isHosted)
        individualService = Reading(directory.hasIndividualService)
        registered = Reading(directory.hasRegistration)
        removed = Reading(directory.isRemoved)
        unregistering = Reading(directory.unregisteringRepository)
        installationOwner = Reading(directory.incompleteInstallationOwner)
        if case .value(true) = registered {
            registrationSettings = Reading { try directory.registration(as: Registration.self) }
        } else {
            registrationSettings = nil
        }
    }

    var registrationFile: String { URL(filePath: path).appending(path: ".runner").path(percentEncoded: false) }

    func isHosted() throws -> Bool { try hosted.get() }
    func hasIndividualService() throws -> Bool { try individualService.get() }
    func hasRegistration() throws -> Bool { try registered.get() }
    func isRemoved() throws -> Bool { try removed.get() }
    func unregisteringRepository() throws -> String? { try unregistering.get() }
    func incompleteInstallationOwner() throws -> String? { try installationOwner.get() }

    func jobRunnerName() throws -> String? { try jobName?.get() }

    func registration() throws -> Registration {
        guard try registered.get(), let registrationSettings else {
            throw ProvisioningError("\(registrationFile) does not exist.")
        }
        return try registrationSettings.get()
    }
}

/// This Mac's runner folders, which the provisioner reads and changes directly.
struct LocalRunnerMac: RunnerMac {
    let installation: HostInstallation
    var reservations = GitHubJobReservations()
    let resolveHostName: @Sendable () -> String
    let prepare: @Sendable (GitHubRunnerDownload) async throws -> URL
    let installRunner: @Sendable (RunnerProvisioner.InstallationRequest) async throws -> Void

    func hostName() -> String { resolveHostName() }

    func runners() throws -> RunnerInventory {
        let scan = try installation.runnerDirectories()
        return RunnerInventory(
            folders: scan.directories.map(RunnerFolder.init(reading:)),
            unreadable: scan.unreadable.map {
                .init(registrationFile: $0.directory.registrationFile.path(percentEncoded: false), reason: $0.error.localizedDescription)
            },
            entryNames: Set(scan.directories.map(\.name) + scan.unreadable.map(\.directory.name) + scan.otherEntries.map(\.lastPathComponent)),
            labels: try installation.runnerLabels(), appliedLabels: try installation.appliedRunnerLabels()
        )
    }

    func prepareArchive(_ download: GitHubRunnerDownload) async throws -> URL { try await prepare(download) }

    func install(_ request: RunnerProvisioner.InstallationRequest) async throws { try await installRunner(request) }

    @MainActor func markUnregistering(_ runner: String, from repositoryID: Int) throws -> Bool {
        let folder = try directory(named: runner)
        try folder.markUnregistering(from: repositoryID)
        return !reservations.contains(folder.url)
    }

    func retainRegistration(_ runner: String) throws { try directory(named: runner).clearUnregistering() }

    func markRemoved(_ runner: String) throws { try directory(named: runner).markRemoved() }

    func markLabelsApplied(_ labels: [String]) throws { try installation.saveAppliedRunnerLabels(labels) }

    private func directory(named name: String) throws -> RunnerDirectory {
        guard let directory = try installation.runnerDirectories().directories.first(where: { $0.name == name }) else {
            throw ProvisioningError("This Mac has no runner folder named \(name).")
        }
        return directory
    }
}
