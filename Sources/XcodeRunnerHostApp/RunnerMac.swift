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
    func markUnregistering(_ runner: String, from repositoryID: Int) async throws
    func markRemoved(_ runner: String) async throws
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

    init(reading directory: RunnerDirectory) {
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
            entryNames: Set(scan.directories.map(\.name) + scan.unreadable.map(\.directory.name) + scan.otherEntries.map(\.lastPathComponent))
        )
    }

    func prepareArchive(_ download: GitHubRunnerDownload) async throws -> URL { try await prepare(download) }

    func install(_ request: RunnerProvisioner.InstallationRequest) async throws { try await installRunner(request) }

    func markUnregistering(_ runner: String, from repositoryID: Int) throws {
        try directory(named: runner).markUnregistering(from: repositoryID)
    }

    func markRemoved(_ runner: String) throws { try directory(named: runner).markRemoved() }

    private func directory(named name: String) throws -> RunnerDirectory {
        guard let directory = try installation.runnerDirectories().directories.first(where: { $0.name == name }) else {
            throw ProvisioningError("This Mac has no runner folder named \(name).")
        }
        return directory
    }
}
