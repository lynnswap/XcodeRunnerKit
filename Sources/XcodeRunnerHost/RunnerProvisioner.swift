import CryptoKit
import Foundation
import Subprocess
import XcodeRunnerKit

struct RepositoryRunnerStatus: Sendable, Identifiable {
    let repository: GitHubRepository
    let desiredCount: Int
    let registeredCount: Int
    let onlineCount: Int
    let busyCount: Int
    let excessCount: Int
    let errorMessage: String?
    let requiresAuthentication: Bool

    var id: Int { repository.id }
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
    }

    private struct Registration: Decodable {
        let agentId: Int
        let agentName: String?
        let gitHubUrl: String?
        let serverUrl: String?
    }

    private struct LocalRunner {
        let name: String
        let registration: Registration
        let hasIndividualService: Bool
        let isHosted: Bool

        var repositoryFullName: String? {
            guard let rawURL = registration.gitHubUrl ?? registration.serverUrl,
                  let url = URL(string: rawURL), url.host()?.lowercased() == "github.com" else { return nil }
            let name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return name.split(separator: "/").count == 2 ? name : nil
        }

        func matches(_ remote: GitHubRunner) -> Bool {
            registration.agentId == remote.id && name == remote.name
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

    func reconcile(
        repositories: [GitHubRepository], capacity: Int, token: String
    ) async -> [RepositoryRunnerStatus] {
        guard !isReconciling else {
            return repositories.map {
                Self.status(repository: $0, capacity: capacity, runners: [], error: "Runner configuration is already being applied.")
            }
        }
        isReconciling = true
        defer { isReconciling = false }
        var archive: Result<PreparedArchive, any Error>?
        var statuses: [RepositoryRunnerStatus] = []
        let initialLocal: [LocalRunner]
        do { initialLocal = try localRunners() }
        catch {
            return repositories.map {
                Self.status(repository: $0, capacity: capacity, runners: [], error: error.localizedDescription)
            }
        }
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

        for repository in repositories {
            var knownRunners: [GitHubRunner] = []
            var messages: [String] = []
            var requiresAuthentication = false
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
                    messages.append("\(individualCount) runner(s) use an individual service and were left unchanged.")
                }
                let unhosted = local.filter { !$0.isHosted && !$0.hasIndividualService }
                if !unhosted.isEmpty {
                    messages.append("\(unhosted.count) registration(s) have not opted in to this host and were left unchanged.")
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
                            while true {
                                let candidate = Self.runnerName(hostName: hostName, repository: repository, slot: nextSlot)
                                nextSlot += 1
                                if !remote.contains(where: { $0.name == candidate }),
                                   !FileManager.default.fileExists(atPath: installation.runnersRoot.appending(path: candidate).path(percentEncoded: false)) {
                                    name = candidate
                                    break
                                }
                            }
                            try await installRunner(InstallationRequest(
                                repository: repository, runnerName: name, archive: prepared.url,
                                sha256Checksum: prepared.checksum, registrationToken: registrationToken, labels: labels
                            ))
                        }
                    } catch {
                        messages.append(error.localizedDescription.replacingOccurrences(of: registrationToken, with: "[redacted]"))
                    }
                    // A failed installer can still have registered a runner. Preserve and report that partial result.
                    remote = try await client.listRunners(repository: repository, accessToken: token)
                    local = try localRunners().filter {
                        try $0.belongs(to: repository, remote: remote, resolvedRepositories: resolvedRepositories)
                    }
                    knownRunners = Self.managedRunners(local: local, remote: remote)
                }
            } catch {
                messages.append(error.localizedDescription)
                if let error = error as? GitHubError, case .response(status: 401, message: _) = error {
                    requiresAuthentication = true
                }
            }
            statuses.append(Self.status(
                repository: repository, capacity: capacity, runners: knownRunners,
                error: messages.isEmpty ? nil : messages.joined(separator: " "),
                requiresAuthentication: requiresAuthentication
            ))
        }
        return statuses
    }

    private func localRunners() throws -> [LocalRunner] {
        let manager = FileManager.default
        let directories: [URL]
        do {
            directories = try manager.contentsOfDirectory(at: installation.runnersRoot, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try directories.compactMap { directory in
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return nil }
            let metadata = directory.appending(path: ".runner")
            guard manager.fileExists(atPath: metadata.path(percentEncoded: false)) else { return nil }
            do {
                let registration = try JSONDecoder().decode(Registration.self, from: Data(contentsOf: metadata))
                return LocalRunner(
                    name: registration.agentName ?? directory.lastPathComponent, registration: registration,
                    hasIndividualService: manager.fileExists(atPath: directory.appending(path: ".service").path(percentEncoded: false)),
                    isHosted: manager.fileExists(atPath: directory.appending(path: ".xcode-runner-host").path(percentEncoded: false))
                )
            } catch {
                throw ProvisioningError("Could not read the registration at \(metadata.path(percentEncoded: false)): \(error.localizedDescription)")
            }
        }
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
        repository: GitHubRepository, capacity: Int, runners: [GitHubRunner], error: String?,
        requiresAuthentication: Bool = false
    ) -> RepositoryRunnerStatus {
        RepositoryRunnerStatus(
            repository: repository, desiredCount: capacity, registeredCount: runners.count,
            onlineCount: runners.count(where: { $0.status == "online" }), busyCount: runners.count(where: \.busy),
            excessCount: max(0, runners.count - capacity), errorMessage: error,
            requiresAuthentication: requiresAuthentication
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
            environment: .inherit.updating(["HOME": installation.homeDirectory.path(percentEncoded: false)]),
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
