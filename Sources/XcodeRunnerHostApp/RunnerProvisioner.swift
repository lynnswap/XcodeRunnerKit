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
    /// Whether the repository left the selection, so `registeredCount` counts this Mac's runners still to remove.
    var isUnlinked = false

    /// Whether this Mac has no runners left to remove for a repository that left the selection.
    var hasFinishedRemoval: Bool { isUnlinked && registeredCount == 0 && problems.isEmpty }

    var id: Int { repository.id }

    /// The problems as one line of display text, or nil when there are none.
    var errorMessage: String? { problems.isEmpty ? nil : problems.map(\.message).joined(separator: " ") }
}

extension RepositoryRunnerStatus {
    /// Each repository's runners on every Mac. A problem on a Mac that this host manages starts with its name.
    ///
    /// - Parameter macs: Each Mac's statuses, where a `nil` name is this Mac.
    static func combining(_ macs: [(name: String?, statuses: [RepositoryRunnerStatus])]) -> [RepositoryRunnerStatus] {
        var combined: [RepositoryRunnerStatus] = []
        for (name, statuses) in macs {
            for status in statuses {
                let problems = name.map { name in status.problems.map { .failed("\(name): \($0.message)") } } ?? status.problems
                let previous = combined.firstIndex { $0.id == status.id }
                let sum = { (count: KeyPath<RepositoryRunnerStatus, Int>) in
                    status[keyPath: count] + (previous.map { combined[$0][keyPath: count] } ?? 0)
                }
                let next = RepositoryRunnerStatus(
                    repository: status.repository, desiredCount: sum(\.desiredCount), registeredCount: sum(\.registeredCount),
                    onlineCount: sum(\.onlineCount), busyCount: sum(\.busyCount), excessCount: sum(\.excessCount),
                    problems: (previous.map { combined[$0].problems } ?? []) + problems, isUnlinked: status.isUnlinked
                )
                if let previous { combined[previous] = next } else { combined.append(next) }
            }
        }
        return combined
    }
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
    func removeRunner(_ id: Int, from repository: GitHubRepository, accessToken: String) async throws
    func setCustomLabels(_ labels: [String], ofRunner id: Int, in repository: GitHubRepository, accessToken: String) async throws
}

extension GitHubClient: RunnerProvisioningClient {}

actor RunnerProvisioner {
    struct InstallationRequest: Codable, Sendable {
        let repository: GitHubRepository
        let runnerName: String
        let archive: URL
        let sha256Checksum: String
        let registrationToken: String
        let labels: [String]
        let replaceRegistration: Bool
    }

    private struct LocalRunner {
        let folder: RunnerFolder
        let name: String
        let registration: RunnerFolder.Registration
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

    /// The Mac whose runners this provisioner reconciles.
    let mac: any RunnerMac
    private let client: any RunnerProvisioningClient
    // Resolving the host name can wait on network name lookups, so host startup must not evaluate it.
    private var resolvedHostName: String?
    private var isReconciling = false

    /// Reconciles this Mac's runners.
    init(
        installation: HostInstallation,
        installerURL: URL,
        client: any RunnerProvisioningClient = GitHubClient(),
        hostName: @autoclosure @escaping @Sendable () -> String = ProcessInfo.processInfo.hostName,
        prepareArchive: (@Sendable (GitHubRunnerDownload) async throws -> URL)? = nil,
        installRunner: (@Sendable (InstallationRequest) async throws -> Void)? = nil
    ) {
        self.init(
            mac: LocalRunnerMac(
                installation: installation, resolveHostName: hostName,
                prepare: prepareArchive ?? { download in try await Self.downloadArchive(download, installation: installation) },
                installRunner: installRunner ?? { request in
                    try await Self.runInstaller(request, installerURL: installerURL, installation: installation)
                }
            ),
            client: client
        )
    }

    init(mac: any RunnerMac, client: any RunnerProvisioningClient) {
        self.mac = mac
        self.client = client
    }

    private func hostName() async throws -> String {
        if let resolvedHostName { return resolvedHostName }
        let name = try await mac.hostName()
        resolvedHostName = name
        return name
    }

    /// Runs a managing host's request on this Mac's runner folders, unless runners are being reconciled.
    func perform<Value: Sendable>(_ operation: @Sendable (any RunnerMac) async throws -> Value) async throws -> Value {
        guard !isReconciling else { throw ProvisioningError(RunnerProvisioningProblem.reconciliationInProgress.message) }
        isReconciling = true
        defer { isReconciling = false }
        return try await operation(mac)
    }

    /// Registers enough runners for each repository, removes this Mac's runners of the unlinked repositories, and
    /// reports their state.
    ///
    /// Other failures are reported per repository. Throws
    /// RunnerProvisioningAuthenticationFailure when GitHub rejects the token.
    ///
    /// - Parameter unlinked: Repositories that left the selection. Only runners that GitHub lists for them are
    ///   removed, and a busy runner is removed at a later call, after its job finishes.
    func reconcile(
        repositories: [GitHubRepository], unlinked: [GitHubRepository] = [], capacity: Int, token: String
    ) async throws -> [RepositoryRunnerStatus] {
        guard !isReconciling else {
            return repositories.map {
                Self.status(repository: $0, capacity: capacity, runners: [], problems: [.reconciliationInProgress])
            } + unlinked.map { Self.removalStatus(repository: $0, problems: [.reconciliationInProgress]) }
        }
        isReconciling = true
        defer { isReconciling = false }
        var archive: Result<PreparedArchive, any Error>?
        var statuses: [RepositoryRunnerStatus] = []
        var inventory: RunnerInventory
        do { inventory = try await mac.runners() }
        catch {
            return repositories.map {
                Self.status(repository: $0, capacity: capacity, runners: [], problems: [.failed(error.localizedDescription)])
            } + unlinked.map { Self.removalStatus(repository: $0, problems: [.failed(error.localizedDescription)]) }
        }
        let initialScan = Self.localRunners(in: inventory)
        let initialLocal = initialScan.runners
        var snapshots: [Int: Result<[GitHubRunner], any Error>] = [:]
        for repository in repositories + unlinked {
            do {
                try Task.checkCancellation()
                let runners = try await client.listRunners(repository: repository, accessToken: token)
                snapshots[repository.id] = .success(runners)
            } catch { snapshots[repository.id] = .failure(error) }
        }
        var resolvedRepositories: [String: Result<GitHubRepository?, any Error>] = [:]
        for local in initialLocal {
            guard let fullName = local.repositoryFullName, resolvedRepositories[fullName.lowercased()] == nil else { continue }
            let needsResolution = (repositories + unlinked).contains { repository in
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
        // The Mac's own labels, and the labels of its earlier lists that its runners can still have. GitHub compares
        // labels without regard to case.
        var macLabels = Set(inventory.labels.map { $0.lowercased() })
        let appliedLabels = Set(inventory.appliedLabels.map { $0.lowercased() })
        var retiredLabels = appliedLabels.subtracting(macLabels)
        var labelProblems: [RunnerProvisioningProblem] = []
        if !macLabels.isSubset(of: appliedLabels) {
            // A label is recorded before a runner gets it, so that it can be removed after it leaves the list.
            do {
                try await mac.markLabelsApplied(appliedLabels.union(macLabels).sorted())
            } catch {
                labelProblems = [.failed("Could not record the Mac's runner labels, so they were not changed: \(error.localizedDescription)")]
                macLabels = []
                retiredLabels = []
            }
        }
        var everyRunnerHasItsLabels = labelProblems.isEmpty
        var authenticationError: GitHubError?

        for repository in repositories {
            var knownRunners: [GitHubRunner] = []
            var problems = initialScan.problems + labelProblems
            var hasItsLabels = false
            defer {
                if !hasItsLabels { everyRunnerHasItsLabels = false }
            }
            do {
                try Task.checkCancellation()
                guard let snapshot = snapshots[repository.id] else { throw CancellationError() }
                var remote = try snapshot.get()
                guard let ownership = localOwnership[repository.id] else { throw CancellationError() }
                var local = try ownership.get()
                knownRunners = Self.managedRunners(local: local, remote: remote)
                // Existing runners get the Mac's labels and lose those that left its list. Their other labels stay.
                for runner in knownRunners {
                    let current = Self.customLabels(of: runner)
                    let next = current.subtracting(retiredLabels).union(macLabels)
                    guard next != current else { continue }
                    try await client.setCustomLabels(next.sorted(), ofRunner: runner.id, in: repository, accessToken: token)
                }
                hasItsLabels = true
                let inheritedLabels = knownRunners.isEmpty ? sharedLabels : Self.commonCustomLabels(of: knownRunners)
                let labels = Set(inheritedLabels).subtracting(retiredLabels).union(macLabels).union(["xcode-runnerkit"]).sorted()
                let individualCount = local.count(where: { $0.hasIndividualService })
                if individualCount > 0 {
                    problems.append(.individualServices(count: individualCount))
                }
                let unhosted = try local.filter { runner in
                    guard !runner.isHosted && !runner.hasIndividualService else { return false }
                    return try !canResumeInstallation(at: runner.folder, repository: repository, remote: remote)
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
                                url: try await mac.prepareArchive(download), checksum: download.sha256Checksum
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
                                let candidate = Self.runnerName(hostName: try await hostName(), repository: repository, slot: nextSlot)
                                nextSlot += 1
                                if let folder = inventory.folder(named: candidate),
                                   try canResumeInstallation(at: folder, repository: repository, remote: remote) {
                                    name = candidate
                                    replaceRegistration = try !folder.hasRegistration() && remote.contains(where: { $0.name == candidate })
                                    break
                                }
                                if !remote.contains(where: { $0.name == candidate }), !inventory.entryNames.contains(candidate) {
                                    name = candidate
                                    break
                                }
                            }
                            try await mac.install(InstallationRequest(
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
                    inventory = try await mac.runners()
                    let scan = Self.localRunners(in: inventory)
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
        // Once every runner has the list, the labels that left it are on no runner. If this record is not written,
        // the next call finds nothing to change on the runners and writes it then.
        if everyRunnerHasItsLabels, !retiredLabels.isEmpty { try? await mac.markLabelsApplied(macLabels.sorted()) }

        for repository in unlinked {
            var remaining = 0
            var busyCount = 0
            // A registration that could not be read may be one of this repository's runners.
            var problems = initialScan.problems
            do {
                try Task.checkCancellation()
                // Old repository names were resolved from the first listing.
                _ = try snapshots[repository.id]?.get()
                // Provisioning can take long enough for an idle runner to start a job, so its state is listed again.
                let remote = try await client.listRunners(repository: repository, accessToken: token)
                var candidates: [(folder: RunnerFolder, name: String, registered: GitHubRunner?)] = []
                for runner in initialLocal where runner.isHosted && !runner.hasIndividualService {
                    // A local name alone can belong to another repository that took it after a rename.
                    if let registered = remote.first(where: runner.matches),
                       try runner.belongs(to: repository, remote: remote, resolvedRepositories: resolvedRepositories) {
                        candidates.append((runner.folder, runner.name, registered))
                    } else if try runner.folder.unregisteringRepository() == String(repository.id) {
                        // GitHub removed the registration before the folder could be marked.
                        candidates.append((runner.folder, runner.name, nil))
                    }
                }
                // An installation that stopped before opting in to the host is also this repository's runner.
                for folder in inventory.folders {
                    guard try !folder.isHosted(), try !folder.hasIndividualService(), try !folder.isRemoved(),
                          try folder.incompleteInstallationOwner() == String(repository.id) else { continue }
                    if try folder.hasRegistration() {
                        let registration = try folder.registration()
                        let name = registration.agentName ?? folder.name
                        candidates.append((folder, name, remote.first { $0.id == registration.agentId && $0.name == name }))
                    } else if let registered = remote.first(where: { $0.name == folder.name }) {
                        // The official runner registers remotely before saving its local .runner settings, so this
                        // installation's registration cannot be online. Another Mac with the same name can own one that is.
                        guard registered.status == "offline", !registered.busy else {
                            remaining += 1
                            problems.append(.failed("The incomplete runner \(registered.name) must be offline and idle before it can be removed. It was left unchanged."))
                            continue
                        }
                        candidates.append((folder, folder.name, registered))
                    } else {
                        candidates.append((folder, folder.name, nil))
                    }
                }
                for candidate in candidates {
                    if let registered = candidate.registered {
                        // A busy runner is removed after its job, at a later synchronization.
                        guard !registered.busy else {
                            remaining += 1
                            busyCount += 1
                            continue
                        }
                        do {
                            try await mac.markUnregistering(candidate.folder.name, from: repository.id)
                        } catch {
                            remaining += 1
                            problems.append(.failed("Could not stop \(candidate.name): \(error.localizedDescription)"))
                            continue
                        }
                        do {
                            try await client.removeRunner(registered.id, from: repository, accessToken: token)
                        } catch GitHubError.response(status: 422, message: _) {
                            // GitHub refuses to remove a runner that started a job after the listing.
                            remaining += 1
                            busyCount += 1
                            continue
                        } catch {
                            remaining += 1
                            problems.append(.failed("Could not remove \(candidate.name) from GitHub: \(error.localizedDescription)"))
                            if let error = error as? GitHubError, case .response(status: 401, message: _) = error {
                                authenticationError = error
                            }
                            continue
                        }
                    }
                    do {
                        try await mac.markRemoved(candidate.folder.name)
                    } catch {
                        remaining += 1
                        problems.append(.failed("Could not stop \(candidate.name): \(error.localizedDescription)"))
                    }
                }
            } catch {
                problems.append(.failed(error.localizedDescription))
                if let error = error as? GitHubError, case .response(status: 401, message: _) = error {
                    authenticationError = error
                }
            }
            statuses.append(Self.removalStatus(
                repository: repository, remaining: remaining, busyCount: busyCount, problems: problems
            ))
        }
        if let authenticationError {
            throw RunnerProvisioningAuthenticationFailure(statuses: statuses, underlyingError: authenticationError)
        }
        return statuses
    }

    private func canResumeInstallation(
        at runner: RunnerFolder, repository: GitHubRepository, remote: [GitHubRunner]
    ) throws -> Bool {
        // A folder that the host is about to delete cannot hold a new registration.
        guard try !runner.isHosted(), try !runner.hasIndividualService(), try !runner.isRemoved(),
              try runner.incompleteInstallationOwner() == String(repository.id) else { return false }
        if try runner.hasRegistration() {
            let registration = try runner.registration()
            let name = registration.agentName ?? runner.name
            guard name == runner.name, remote.contains(where: { $0.id == registration.agentId && $0.name == name }) else {
                throw ProvisioningError("The incomplete registration at \(runner.path) could not be matched to this repository on GitHub. It was left unchanged.")
            }
        } else if let registered = remote.first(where: { $0.name == runner.name }) {
            // The official runner registers remotely before saving its local .runner settings.
            guard registered.status == "offline", !registered.busy else {
                throw ProvisioningError("The incomplete runner \(registered.name) must be offline and idle before its registration can be recovered. It was left unchanged.")
            }
        }
        return true
    }

    private static func localRunners(in inventory: RunnerInventory) -> (runners: [LocalRunner], problems: [RunnerProvisioningProblem]) {
        var runners: [LocalRunner] = []
        // An entry whose type cannot be read is reported for that runner alone.
        var problems: [RunnerProvisioningProblem] = inventory.unreadable.map {
            .unreadableRegistration(path: $0.registrationFile, reason: $0.reason)
        }
        for runner in inventory.folders {
            do {
                // A removed runner's folder stays until the host stops its service.
                guard try runner.hasRegistration(), try !runner.isRemoved() else { continue }
                let registration = try runner.registration()
                runners.append(LocalRunner(
                    folder: runner, name: registration.agentName ?? runner.name, registration: registration,
                    hasIndividualService: try runner.hasIndividualService(), isHosted: try runner.isHosted()
                ))
            } catch {
                problems.append(.unreadableRegistration(path: runner.registrationFile, reason: error.localizedDescription))
            }
        }
        return (runners, problems)
    }

    private static func managedRunners(local: [LocalRunner], remote: [GitHubRunner]) -> [GitHubRunner] {
        let hosted = local.filter { $0.isHosted && !$0.hasIndividualService }
        return remote.filter { runner in hosted.contains(where: { $0.matches(runner) }) }
    }

    private static func commonCustomLabels(of runners: [GitHubRunner]) -> [String] {
        let labelSets = runners.map(customLabels)
        guard let first = labelSets.first else { return [] }
        return labelSets.dropFirst().reduce(first) { $0.intersection($1) }.sorted()
    }

    /// The labels that a runner has besides those that GitHub sets itself.
    private static func customLabels(of runner: GitHubRunner) -> Set<String> {
        let defaults: Set<String> = ["self-hosted", "macos", "arm64"]
        return Set(runner.labels.map { $0.name.lowercased() }.filter { !defaults.contains($0) })
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

    private static func removalStatus(
        repository: GitHubRepository, remaining: Int = 0, busyCount: Int = 0, problems: [RunnerProvisioningProblem]
    ) -> RepositoryRunnerStatus {
        RepositoryRunnerStatus(
            repository: repository, desiredCount: 0, registeredCount: remaining, onlineCount: 0, busyCount: busyCount,
            excessCount: 0, problems: problems, isUnlinked: true
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

struct ProvisioningError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
