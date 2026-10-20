import CryptoKit
import Foundation
import Subprocess
import XcodeRunnerHostSupport
import XcodeRunnerKit

/// A problem found while reconciling one repository's runners.
enum RunnerProvisioningProblem: Sendable, Equatable {
    case reconciliationInProgress
    case unreadableRegistration(path: String, reason: String)
    case individualServices(count: Int)
    case unhostedRegistrations(count: Int)
    case repositoryInaccessible
    /// A failure whose description has had any registration token removed.
    case failed(String)

    var message: String {
        switch self {
        case .reconciliationInProgress: "Runner configuration is already being applied."
        case let .unreadableRegistration(path, reason): "Could not read the registration at \(path): \(reason)"
        case .individualServices(let count): "\(count) runner(s) use an individual service and were left unchanged."
        case .unhostedRegistrations(let count): "\(count) registration(s) have not opted in to this host and were left unchanged."
        case .repositoryInaccessible:
            "This repository is no longer accessible to the GitHub App. Check its installation and permissions, then reload repositories."
        case .failed(let description): description
        }
    }
}

struct RepositoryRunnerStatus: Sendable, Identifiable {
    let repository: GitHubRepository
    let desiredCount: Int
    let registeredCount: Int
    let onlineCount: Int
    let busyCount: Int
    let excessCount: Int
    let problems: [RunnerProvisioningProblem]

    var id: Int { repository.id }

    /// The problems as one line of display text, or nil when there are none.
    var errorMessage: String? { problems.isEmpty ? nil : problems.map(\.message).joined(separator: " ") }
}

/// GitHub rejected the access token while runners were reconciled.
///
/// `statuses` describes every repository at that point, so callers can keep
/// showing them while they refresh the token or ask the user to sign in.
struct RunnerProvisioningAuthenticationFailure: Error {
    let statuses: [RepositoryRunnerStatus]
    let underlyingError: GitHubError
}

protocol RunnerProvisioningClient: Sendable {
    func repository(fullName: String, accessToken: String) async throws -> GitHubRepository
    func listRunners(repository: GitHubRepository, accessToken: String) async throws -> [GitHubRunner]
    func registrationToken(repository: GitHubRepository, accessToken: String) async throws -> String
    func runnerDownload(accessToken: String) async throws -> GitHubRunnerDownload
}

extension GitHubClient: RunnerProvisioningClient {}

actor RunnerProvisioner {
    struct InstallationRequest: Sendable {
        let repository: GitHubRepository
        let runnerName: String
        let archive: URL
        let sha256Checksum: String
        let registrationToken: String
        let labels: [String]
        let replaceRegistration: Bool
    }

    private struct LocalRunner {
        let directory: RunnerDirectory
        let name: String
        let agentId: Int
        let repositoryURL: String?
        let hasIndividualService: Bool
        let isHosted: Bool

        var repositoryFullName: String? {
            guard let repositoryURL, let url = URL(string: repositoryURL), url.host()?.lowercased() == "github.com" else { return nil }
            let name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return name.split(separator: "/").count == 2 ? name : nil
        }

        func matches(_ remote: GitHubRunner) -> Bool {
            agentId == remote.id && name == remote.name
        }

        func belongs(
            to repository: GitHubRepository, remote: [GitHubRunner],
            resolvedRepositories: [String: Result<GitHubRepository?, any Error>]
        ) throws -> Bool {
            guard let fullName = repositoryFullName else { return false }
            if fullName.caseInsensitiveCompare(repository.fullName) == .orderedSame { return true }
            guard remote.contains(where: matches), let resolved = resolvedRepositories[fullName.lowercased()] else { return false }
            return try resolved.get()?.id == repository.id
        }
    }

    private struct PreparedArchive {
        let url: URL
        let checksum: String
    }

    private let installation: HostInstallation
    private let client: any RunnerProvisioningClient
    private let prepareArchive: @Sendable (GitHubRunnerDownload) async throws -> URL
    private let installRunner: @Sendable (InstallationRequest) async throws -> Void
    private let hostName: String
    private var isReconciling = false

    init(
        installation: HostInstallation,
        installerURL: URL,
        client: any RunnerProvisioningClient = GitHubClient(),
        hostName: String = ProcessInfo.processInfo.hostName,
        prepareArchive: (@Sendable (GitHubRunnerDownload) async throws -> URL)? = nil,
        installRunner: (@Sendable (InstallationRequest) async throws -> Void)? = nil
    ) {
        self.installation = installation
        self.client = client
        self.hostName = hostName
        self.prepareArchive = prepareArchive ?? { download in
            try await Self.downloadArchive(download, installation: installation)
        }
        self.installRunner = installRunner ?? { request in
            try await Self.runInstaller(request, installerURL: installerURL, installation: installation)
        }
    }

    /// Registers enough runners for each repository and reports their state.
    ///
    /// Other failures are reported per repository. Throws
    /// RunnerProvisioningAuthenticationFailure when GitHub rejects the token.
    func reconcile(
        repositories: [GitHubRepository], capacity: Int, token: String
    ) async throws -> [RepositoryRunnerStatus] {
        guard !isReconciling else {
            return repositories.map {
                Self.status(repository: $0, capacity: capacity, runners: [], problems: [.reconciliationInProgress])
            }
        }
        isReconciling = true
        defer { isReconciling = false }
        var archive: Result<PreparedArchive, any Error>?
        var statuses: [RepositoryRunnerStatus] = []
        let initialScan: (runners: [LocalRunner], problems: [RunnerProvisioningProblem])
        do { initialScan = try localRunners() }
        catch {
            return repositories.map {
                Self.status(repository: $0, capacity: capacity, runners: [], problems: [.failed(error.localizedDescription)])
            }
        }
        let initialLocal = initialScan.runners
        var snapshots: [Int: Result<[GitHubRunner], any Error>] = [:]
        for repository in repositories {
            do {
                try Task.checkCancellation()
                let runners = try await client.listRunners(repository: repository, accessToken: token)
                snapshots[repository.id] = .success(runners)
            } catch { snapshots[repository.id] = .failure(error) }
        }
        var resolvedRepositories: [String: Result<GitHubRepository?, any Error>] = [:]
        for local in initialLocal {
            guard let fullName = local.repositoryFullName, resolvedRepositories[fullName.lowercased()] == nil else { continue }
            let needsResolution = repositories.contains { repository in
                guard fullName.caseInsensitiveCompare(repository.fullName) != .orderedSame,
                      let snapshot = snapshots[repository.id], case .success(let remote) = snapshot else { return false }
                return remote.contains(where: local.matches)
            }
            guard needsResolution else { continue }
            do {
                try Task.checkCancellation()
                resolvedRepositories[fullName.lowercased()] = .success(
                    try await client.repository(fullName: fullName, accessToken: token)
                )
            } catch let error as GitHubError {
                if case .response(status: 404, message: _) = error {
                    resolvedRepositories[fullName.lowercased()] = .success(nil)
                } else {
                    resolvedRepositories[fullName.lowercased()] = .failure(error)
                }
            } catch {
                resolvedRepositories[fullName.lowercased()] = .failure(error)
            }
        }
        var localOwnership: [Int: Result<[LocalRunner], any Error>] = [:]
        var sharedRunners: [GitHubRunner] = []
        for repository in repositories {
            guard let snapshot = snapshots[repository.id], case .success(let remote) = snapshot else { continue }
            do {
                let local = try initialLocal.filter {
                    try $0.belongs(to: repository, remote: remote, resolvedRepositories: resolvedRepositories)
                }
                localOwnership[repository.id] = .success(local)
                sharedRunners += Self.managedRunners(local: local, remote: remote)
            } catch { localOwnership[repository.id] = .failure(error) }
        }
        let sharedLabels = Self.commonCustomLabels(of: sharedRunners)
        var authenticationError: GitHubError?

        for repository in repositories {
            var knownRunners: [GitHubRunner] = []
            var problems = initialScan.problems
            do {
                try Task.checkCancellation()
                guard let snapshot = snapshots[repository.id] else { throw CancellationError() }
                var remote = try snapshot.get()
                guard let ownership = localOwnership[repository.id] else { throw CancellationError() }
                var local = try ownership.get()
                knownRunners = Self.managedRunners(local: local, remote: remote)
                let inheritedLabels = knownRunners.isEmpty ? sharedLabels : Self.commonCustomLabels(of: knownRunners)
                let labels = Array(Set(inheritedLabels + ["xcode-runnerkit"])).sorted()
                let individualCount = local.count(where: { $0.hasIndividualService })
                if individualCount > 0 {
                    problems.append(.individualServices(count: individualCount))
                }
                let unhosted = try local.filter { runner in
                    guard !runner.isHosted && !runner.hasIndividualService else { return false }
                    return try !canResumeInstallation(at: runner.directory, repository: repository, remote: remote)
                }
                if !unhosted.isEmpty {
                    problems.append(.unhostedRegistrations(count: unhosted.count))
                }

                let missing = max(0, capacity - knownRunners.count)
                if missing > 0 {
                    let archiveResult: Result<PreparedArchive, any Error>
                    if let archive {
                        archiveResult = archive
                    } else {
                        do {
                            let download = try await client.runnerDownload(accessToken: token)
                            archiveResult = .success(PreparedArchive(
                                url: try await prepareArchive(download), checksum: download.sha256Checksum
                            ))
                        } catch { archiveResult = .failure(error) }
                        archive = archiveResult
                    }
                    let prepared = try archiveResult.get()
                    let registrationToken = try await client.registrationToken(repository: repository, accessToken: token)
                    var nextSlot = 1
                    do {
                        for _ in 0..<missing {
                            try Task.checkCancellation()
                            let name: String
                            var replaceRegistration = false
                            while true {
                                let candidate = Self.runnerName(hostName: hostName, repository: repository, slot: nextSlot)
                                nextSlot += 1
                                let directory = RunnerDirectory(url: installation.runnersRoot.appending(path: candidate))
                                if try canResumeInstallation(at: directory, repository: repository, remote: remote) {
                                    name = candidate
                                    replaceRegistration = try !directory.hasRegistration() && remote.contains(where: { $0.name == candidate })
                                    break
                                }
                                if !remote.contains(where: { $0.name == candidate }),
                                   !FileManager.default.fileExists(atPath: directory.url.path(percentEncoded: false)) {
                                    name = candidate
                                    break
                                }
                            }
                            try await installRunner(InstallationRequest(
                                repository: repository, runnerName: name, archive: prepared.url,
                                sha256Checksum: prepared.checksum, registrationToken: registrationToken, labels: labels,
                                replaceRegistration: replaceRegistration
                            ))
                        }
                    } catch {
                        problems.append(.failed(error.localizedDescription.replacingOccurrences(of: registrationToken, with: "[redacted]")))
                    }
                    // A failed installer can still have registered a runner. Preserve and report that partial result.
                    remote = try await client.listRunners(repository: repository, accessToken: token)
                    let scan = try localRunners()
                    for problem in scan.problems where !problems.contains(problem) { problems.append(problem) }
                    local = try scan.runners.filter {
                        try $0.belongs(to: repository, remote: remote, resolvedRepositories: resolvedRepositories)
                    }
                    knownRunners = Self.managedRunners(local: local, remote: remote)
                }
            } catch {
                problems.append(.failed(error.localizedDescription))
                if let error = error as? GitHubError, case .response(status: 401, message: _) = error {
                    authenticationError = error
                }
            }
            statuses.append(Self.status(repository: repository, capacity: capacity, runners: knownRunners, problems: problems))
        }
        if let authenticationError {
            throw RunnerProvisioningAuthenticationFailure(statuses: statuses, underlyingError: authenticationError)
        }
        return statuses
    }

    private func canResumeInstallation(
        at runner: RunnerDirectory, repository: GitHubRepository, remote: [GitHubRunner]
    ) throws -> Bool {
        guard try !runner.isHosted(), try !runner.hasIndividualService(),
              try runner.incompleteInstallationOwner() == String(repository.id) else { return false }
        if try runner.hasRegistration() {
            let registration = try runner.registration()
            let name = registration.agentName ?? runner.name
            guard name == runner.name, let agentId = registration.agentId,
                  remote.contains(where: { $0.id == agentId && $0.name == name }) else {
                throw ProvisioningError("The incomplete registration at \(runner.url.path(percentEncoded: false)) could not be matched to this repository on GitHub. It was left unchanged.")
            }
        } else if let registered = remote.first(where: { $0.name == runner.name }) {
            // The official runner registers remotely before saving its local .runner settings.
            guard registered.status == "offline", !registered.busy else {
                throw ProvisioningError("The incomplete runner \(registered.name) must be offline and idle before its registration can be recovered. It was left unchanged.")
            }
        }
        return true
    }

    private func localRunners() throws -> (runners: [LocalRunner], problems: [RunnerProvisioningProblem]) {
        var runners: [LocalRunner] = []
        var problems: [RunnerProvisioningProblem] = []
        for runner in try installation.runnerDirectories() {
            do {
                guard try runner.hasRegistration() else { continue }
                let registration = try runner.registration()
                guard let agentId = registration.agentId else { throw ProvisioningError("The registration has no runner ID.") }
                runners.append(LocalRunner(
                    directory: runner, name: registration.agentName ?? runner.name, agentId: agentId,
                    repositoryURL: registration.gitHubUrl ?? registration.serverUrl,
                    hasIndividualService: try runner.hasIndividualService(), isHosted: try runner.isHosted()
                ))
            } catch {
                problems.append(.unreadableRegistration(
                    path: runner.registrationFile.path(percentEncoded: false), reason: error.localizedDescription
                ))
            }
        }
        return (runners, problems)
    }

    private static func managedRunners(local: [LocalRunner], remote: [GitHubRunner]) -> [GitHubRunner] {
        let hosted = local.filter { $0.isHosted && !$0.hasIndividualService }
        return remote.filter { runner in hosted.contains(where: { $0.matches(runner) }) }
    }

    private static func commonCustomLabels(of runners: [GitHubRunner]) -> [String] {
        let defaults: Set<String> = ["self-hosted", "macos", "arm64"]
        let labelSets = runners.map { runner in
            Set(runner.labels.map { $0.name.lowercased() }.filter { !defaults.contains($0) })
        }
        guard let first = labelSets.first else { return [] }
        return labelSets.dropFirst().reduce(first) { $0.intersection($1) }.sorted()
    }

    private static func status(
        repository: GitHubRepository, capacity: Int, runners: [GitHubRunner], problems: [RunnerProvisioningProblem]
    ) -> RepositoryRunnerStatus {
        RepositoryRunnerStatus(
            repository: repository, desiredCount: capacity, registeredCount: runners.count,
            onlineCount: runners.count(where: { $0.status == "online" }), busyCount: runners.count(where: \.busy),
            excessCount: max(0, runners.count - capacity), problems: problems
        )
    }

    static func runnerName(hostName: String, repository: GitHubRepository, slot: Int) -> String {
        func component(_ text: String) -> String {
            String(text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }.prefix(24))
        }
        let identity = hostName + "/" + repository.fullName
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let repositoryName = repository.fullName.split(separator: "/").last.map(String.init) ?? repository.fullName
        return "xcrk-\(component(hostName))-\(component(repositoryName))-\(hash)-\(slot)"
    }

    static func verifyArchive(at url: URL, checksum: String) throws {
        let actual = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == checksum.lowercased() else {
            throw ProvisioningError("The official runner archive did not match its published SHA-256 checksum.")
        }
    }

    private static func downloadArchive(_ download: GitHubRunnerDownload, installation: HostInstallation) async throws -> URL {
        let manager = FileManager.default
        let directory = installation.hostRoot.appending(path: "Downloads")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appending(path: download.filename)
        if manager.fileExists(atPath: archive.path(percentEncoded: false)) {
            do {
                try verifyArchive(at: archive, checksum: download.sha256Checksum)
                return archive
            } catch is ProvisioningError {
                try manager.removeItem(at: archive)
            }
        }
        let (temporary, response) = try await URLSession.shared.download(from: download.downloadURL)
        do {
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw ProvisioningError("Could not download the official runner archive.")
            }
            try verifyArchive(at: temporary, checksum: download.sha256Checksum)
            try manager.moveItem(at: temporary, to: archive)
            return archive
        } catch {
            do { try manager.removeItem(at: temporary) }
            catch let cleanupError {
                throw ProvisioningError("\(error.localizedDescription) The temporary download could not be removed: \(cleanupError.localizedDescription)")
            }
            throw error
        }
    }

    private static func runInstaller(
        _ request: InstallationRequest, installerURL: URL, installation: HostInstallation
    ) async throws {
        var options = Subprocess.PlatformOptions()
        options.createSession = true
        // Installer descendants inherit the storage lock and must leave with their parent on cancellation.
        options.teardownSequence = [
            .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero),
        ]
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: .init([
                installerURL.path(percentEncoded: false), request.repository.fullName, request.runnerName, request.archive.path(percentEncoded: false),
                request.labels.joined(separator: ","), request.sha256Checksum,
            ]),
            environment: .inherit.updating([
                "HOME": installation.homeDirectory.path(percentEncoded: false),
                "XCODE_RUNNER_INSTALLATION_REPOSITORY_ID": String(request.repository.id),
                "XCODE_RUNNER_REPLACE_REGISTRATION": request.replaceRegistration ? "1" : "0",
            ]),
            platformOptions: options,
            input: .string(request.registrationToken + "\n"),
            output: .string(limit: 1_048_576), error: .string(limit: 1_048_576)
        )
        guard result.terminationStatus.isSuccess else {
            let details = (result.standardError + "\n" + result.standardOutput)
                .replacingOccurrences(of: request.registrationToken, with: "[redacted]")
            throw ProvisioningError("Could not install \(request.runnerName): \(details)")
        }
    }
}

private struct ProvisioningError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
