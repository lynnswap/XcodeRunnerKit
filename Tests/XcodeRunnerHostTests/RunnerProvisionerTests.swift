import Darwin
import Foundation
import Testing
import XcodeRunnerHostSupport
import XcodeRunnerKit
@testable import XcodeRunnerHost

@Suite(.timeLimit(.minutes(1)))
struct RunnerProvisionerTests {
    private let firstRepository = GitHubRepository(id: 1, fullName: "example/First")
    private let secondRepository = GitHubRepository(id: 2, fullName: "example/Second")

    private actor Client: RunnerProvisioningClient {
        let installation: HostInstallation
        var remote: [Int: [GitHubRunner]] = [:]
        var installations: [RunnerProvisioner.InstallationRequest] = []
        var tokenRequests = 0
        var archiveRequests = 0
        var runnerListRequests: [Int] = []
        var failedRepository: Int?
        var failingInstallation: Int?
        var failAfterRegistration = false
        var repositoryResolutions: [String: Result<GitHubRepository, any Error>] = [:]
        var repositoryLookups: [String] = []
        var pendingInstallationFailures = 0
        var failBeforeOptIn = false
        var failBeforeLocalSettings = false
        private var nextIdentifier = 100

        init(installation: HostInstallation) { self.installation = installation }

        func resolveRepository(_ fullName: String, as result: Result<GitHubRepository, any Error>) {
            repositoryResolutions[fullName.lowercased()] = result
        }

        func repository(fullName: String, accessToken: String) throws -> GitHubRepository {
            repositoryLookups.append(fullName)
            guard let result = repositoryResolutions[fullName.lowercased()] else {
                throw GitHubError.response(status: 404, message: "Repository not found.")
            }
            return try result.get()
        }

        func configureFailure(repository: Int? = nil, installation: Int? = nil, afterRegistration: Bool = false) {
            failedRepository = repository
            failingInstallation = installation
            failAfterRegistration = afterRegistration
        }

        func configurePendingFailures(
            count: Int, afterRegistration: Bool = false, beforeLocalSettings: Bool = false
        ) {
            pendingInstallationFailures = count
            failBeforeOptIn = afterRegistration
            failBeforeLocalSettings = beforeLocalSettings
        }

        func listRunners(repository: GitHubRepository, accessToken: String) throws -> [GitHubRunner] {
            runnerListRequests.append(repository.id)
            if failedRepository == repository.id { throw TestFailure("Repository access denied.") }
            return remote[repository.id, default: []]
        }

        func registrationToken(repository: GitHubRepository, accessToken: String) throws -> String {
            tokenRequests += 1
            return "short-lived-registration-token"
        }

        func runnerDownload(accessToken: String) throws -> GitHubRunnerDownload {
            archiveRequests += 1
            return GitHubRunnerDownload(
                filename: "actions-runner-osx-arm64-test.tar.gz",
                downloadURL: URL(string: "https://example.invalid/runner.tar.gz")!,
                sha256Checksum: "test-checksum"
            )
        }

        func addRunner(
            repository: GitHubRepository, identifier: Int, name: String, hosted: Bool = true,
            individualService: Bool = false, online: Bool = true, busy: Bool = false,
            localRepository: GitHubRepository? = nil, localIdentifier: Int? = nil,
            labels: [String] = ["self-hosted", "macOS", "ARM64", "xcode-runnerkit"]
        ) throws {
            remote[repository.id, default: []].append(GitHubRunner(
                id: identifier, name: name, status: online ? "online" : "offline", busy: busy,
                labels: labels.map { GitHubRunnerLabel(name: $0) }
            ))
            let directory = installation.runnersRoot.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let metadata: [String: Any] = [
                "agentId": localIdentifier ?? identifier,
                "agentName": name,
                "gitHubUrl": "https://github.com/\((localRepository ?? repository).fullName)",
            ]
            try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appending(path: ".runner"))
            if hosted { try Data().write(to: directory.appending(path: ".xcode-runner-host")) }
            if individualService { try Data().write(to: directory.appending(path: ".service")) }
        }

        func addRemoteRunner(
            repository: GitHubRepository, identifier: Int, name: String, online: Bool = true, busy: Bool = true
        ) {
            remote[repository.id, default: []].append(GitHubRunner(
                id: identifier, name: name, status: online ? "online" : "offline", busy: busy, labels: []
            ))
        }

        func install(_ request: RunnerProvisioner.InstallationRequest) throws {
            installations.append(request)
            let directory = installation.runnersRoot.appending(path: request.runnerName)
            let owner = directory.appending(path: ".xcode-runner-installation")
            if pendingInstallationFailures > 0 {
                pendingInstallationFailures -= 1
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try String(request.repository.id).write(to: owner, atomically: true, encoding: .utf8)
                if failBeforeOptIn {
                    try addRunner(
                        repository: request.repository, identifier: nextIdentifier, name: request.runnerName, hosted: false
                    )
                    nextIdentifier += 1
                } else if failBeforeLocalSettings {
                    addRemoteRunner(
                        repository: request.repository, identifier: nextIdentifier, name: request.runnerName,
                        online: false, busy: false
                    )
                    nextIdentifier += 1
                } else {
                    try Data("extracted runner archive".utf8).write(to: directory.appending(path: "config.sh"))
                }
                throw TestFailure("Installation was interrupted.")
            }
            if FileManager.default.fileExists(atPath: owner.path(percentEncoded: false)),
               FileManager.default.fileExists(atPath: directory.appending(path: ".runner").path(percentEncoded: false)) {
                try Data().write(to: directory.appending(path: ".xcode-runner-host"))
                try FileManager.default.removeItem(at: owner)
                return
            }
            let shouldFail = installations.count == failingInstallation
            if shouldFail && !failAfterRegistration { throw TestFailure("Installation failed: \(request.registrationToken)") }
            var identifier = nextIdentifier
            if request.replaceRegistration {
                identifier = remote[request.repository.id, default: []].first(where: { $0.name == request.runnerName })?.id ?? identifier
                remote[request.repository.id, default: []].removeAll { $0.name == request.runnerName }
            }
            defer { nextIdentifier += 1 }
            try addRunner(repository: request.repository, identifier: identifier, name: request.runnerName)
            if shouldFail { throw TestFailure("Installation failed after registration.") }
            if FileManager.default.fileExists(atPath: owner.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: owner)
            }
        }
    }

    private struct TestFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func fixture() throws -> (root: URL, client: Client, provisioner: RunnerProvisioner) {
        let root = URL.temporaryDirectory.appending(path: "Runner provisioning \(UUID().uuidString)")
        let installation = HostInstallation(homeDirectory: root)
        let client = Client(installation: installation)
        return (root, client, RunnerProvisioner(
            installation: installation, installerURL: root.appending(path: "unused-installer.sh"), client: client,
            hostName: "CI Mac", prepareArchive: { _ in root.appending(path: "verified-runner.tar.gz") },
            installRunner: { try await client.install($0) }
        ))
    }

    @Test func existingManagedRunnersAreAdoptedAndOnlyMissingListenersAreInstalled() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await client.addRunner(repository: firstRepository, identifier: 1, name: "existing", busy: true)
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 3, token: "access-token")
        let status = try #require(statuses.first)
        #expect(status.registeredCount == 3)
        #expect(status.onlineCount == 3)
        #expect(status.busyCount == 1)
        #expect(status.errorMessage == nil)
        #expect(await client.installations.count == 2)
        #expect(await client.tokenRequests == 1)
        let repeated = try await provisioner.reconcile(repositories: [firstRepository], capacity: 3, token: "access-token")
        #expect(repeated.first?.registeredCount == 3)
        #expect(await client.installations.count == 2)
    }

    @Test func eachRepositoryReceivesTheSharedCapacityAndArchiveIsPreparedOnce() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let statuses = try await provisioner.reconcile(
            repositories: [firstRepository, secondRepository], capacity: 2, token: "access-token"
        )
        #expect(statuses.map(\.registeredCount) == [2, 2])
        #expect(await client.installations.count == 4)
        #expect(await client.archiveRequests == 1)
        #expect(await client.tokenRequests == 2)
    }

    @Test func malformedUnselectedRegistrationIsReportedWithoutBlockingSelectedRepositories() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Library/XcodeRunnerKit/runners/unselected-malformed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appending(path: ".runner")
        let malformed = Data(#"{"agentId":"#.utf8)
        try malformed.write(to: metadata)
        let statuses = try await provisioner.reconcile(
            repositories: [firstRepository, secondRepository], capacity: 1, token: "access-token"
        )
        #expect(statuses.map(\.registeredCount) == [1, 1])
        #expect(Set(await client.runnerListRequests) == Set([firstRepository.id, secondRepository.id]))
        for status in statuses {
            let message = try #require(status.errorMessage)
            #expect(message.components(separatedBy: metadata.path(percentEncoded: false)).count == 2)
        }
        #expect(try Data(contentsOf: metadata) == malformed)
    }

    @Test func malformedOwnedPendingRegistrationStopsOnlyItsRepository() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = RunnerProvisioner.runnerName(hostName: "CI Mac", repository: firstRepository, slot: 1)
        let directory = root.appending(path: "Library/XcodeRunnerKit/runners/\(name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try String(firstRepository.id).write(
            to: directory.appending(path: ".xcode-runner-installation"), atomically: true, encoding: .utf8
        )
        let metadata = directory.appending(path: ".runner")
        let malformed = Data(#"{"agentId":"#.utf8)
        try malformed.write(to: metadata)
        let statuses = try await provisioner.reconcile(
            repositories: [firstRepository, secondRepository], capacity: 1, token: "access-token"
        )
        #expect(statuses.map(\.registeredCount) == [0, 1])
        #expect(await client.installations.map(\.repository.id) == [secondRepository.id])
        #expect(statuses.allSatisfy { $0.errorMessage?.contains(metadata.path(percentEncoded: false)) == true })
        #expect(try Data(contentsOf: metadata) == malformed)
    }

    @Test func hostLabelsAreInheritedAndSharedWithNewRepositories() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await client.addRunner(
            repository: firstRepository, identifier: 1, name: "existing-first",
            labels: ["self-hosted", "macOS", "ARM64", "m1pro", "xcode-runnerkit", "ci-interactive"]
        )
        try await client.addRunner(
            repository: firstRepository, identifier: 2, name: "existing-second",
            labels: ["self-hosted", "macOS", "ARM64", "m1pro", "xcode-runnerkit", "ci-batch"]
        )
        _ = try await provisioner.reconcile(repositories: [firstRepository, secondRepository], capacity: 3, token: "access-token")
        let requests = await client.installations
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.labels == ["m1pro", "xcode-runnerkit"] })
    }

    @Test func decreasingCapacityPreservesBusyAndIdleListeners() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await client.addRunner(repository: firstRepository, identifier: 1, name: "busy", busy: true)
        try await client.addRunner(repository: firstRepository, identifier: 2, name: "idle")
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        let status = try #require(statuses.first)
        #expect(status.registeredCount == 2)
        #expect(status.excessCount == 1)
        #expect(status.busyCount == 1)
        #expect(await client.installations.isEmpty)
        #expect(await client.archiveRequests == 0)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Library/XcodeRunnerKit/runners/busy/.runner").path(percentEncoded: false)))
    }

    @Test func remoteRunnersOnOtherHostsAndUnmatchedLocalIdentifiersDoNotReduceTheTarget() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await client.addRemoteRunner(repository: firstRepository, identifier: 1, name: "other-host")
        try await client.addRunner(
            repository: firstRepository, identifier: 2, name: "unmatched-local-id", localIdentifier: 3
        )
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(statuses.first?.registeredCount == 1)
        #expect(await client.installations.count == 1)
    }

    @Test func renamedRepositoryKeepsItsLocalRunnersAndResolvesTheOldNameOnce() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = GitHubRepository(id: firstRepository.id, fullName: "example/Renamed")
        try await client.addRunner(repository: renamed, identifier: 1, name: "existing-first", localRepository: firstRepository)
        try await client.addRunner(repository: renamed, identifier: 2, name: "existing-second", localRepository: firstRepository)
        await client.resolveRepository(firstRepository.fullName, as: .success(renamed))
        let statuses = try await provisioner.reconcile(repositories: [renamed], capacity: 2, token: "access-token")
        #expect(statuses.first?.registeredCount == 2)
        #expect(statuses.first?.errorMessage == nil)
        #expect(await client.installations.isEmpty)
        #expect(await client.repositoryLookups == [firstRepository.fullName])
        #expect(await client.archiveRequests == 0)
    }

    @Test func matchingRunnerIDAndNameInAnotherRepositoryDoNotEstablishOwnership() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = GitHubRepository(id: firstRepository.id, fullName: "example/Renamed")
        try await client.addRunner(repository: renamed, identifier: 1, name: "existing", localRepository: firstRepository)
        await client.addRemoteRunner(repository: secondRepository, identifier: 1, name: "existing")
        await client.resolveRepository(firstRepository.fullName, as: .success(renamed))
        let statuses = try await provisioner.reconcile(repositories: [renamed, secondRepository], capacity: 1, token: "access-token")
        #expect(statuses.map(\.registeredCount) == [1, 1])
        let installed = await client.installations
        #expect(installed.count == 1)
        #expect(installed.first?.repository.id == secondRepository.id)
        #expect(await client.repositoryLookups == [firstRepository.fullName])
    }

    @Test func repositoryLookupFailureDoesNotCreateDuplicateRunners() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = GitHubRepository(id: firstRepository.id, fullName: "example/Renamed")
        try await client.addRunner(repository: renamed, identifier: 1, name: "existing", localRepository: firstRepository)
        await client.resolveRepository(firstRepository.fullName, as: .failure(URLError(.networkConnectionLost)))
        let statuses = try await provisioner.reconcile(repositories: [renamed], capacity: 1, token: "access-token")
        #expect(statuses.first?.errorMessage != nil)
        #expect(await client.installations.isEmpty)
        #expect(await client.archiveRequests == 0)
    }

    @Test func individualServicesRemainUnchangedAndAreReported() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await client.addRunner(repository: firstRepository, identifier: 1, name: "individual", individualService: true)
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(statuses.first?.registeredCount == 1)
        #expect(statuses.first?.errorMessage?.contains("individual service") == true)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Library/XcodeRunnerKit/runners/individual/.service").path(percentEncoded: false)))
    }

    @Test func repositoryFailureDoesNotPreventOtherRepositoriesFromBeingConfigured() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await client.configureFailure(repository: firstRepository.id)
        let statuses = try await provisioner.reconcile(
            repositories: [firstRepository, secondRepository], capacity: 1, token: "access-token"
        )
        #expect(statuses.first?.errorMessage == "Repository access denied.")
        #expect(statuses.last?.registeredCount == 1)
        #expect(statuses.last?.errorMessage == nil)
    }

    @Test(arguments: [401, 403])
    func onlyUnauthorizedGitHubResponsesRequireSigningInAgain(statusCode: Int) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let transport = GitHubTestTransport([
            .init(path: "/repos/example/First/actions/runners", body: #"{"message":"Rejected credential"}"#, status: statusCode),
        ])
        let provisioner = RunnerProvisioner(
            installation: HostInstallation(homeDirectory: root), installerURL: root.appending(path: "unused.sh"),
            client: await transport.client
        )
        let statuses: [RepositoryRunnerStatus]
        do {
            statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "revoked-token")
            #expect(statusCode != 401)
        } catch let failure as RunnerProvisioningAuthenticationFailure {
            #expect(statusCode == 401)
            guard case .response(status: 401, message: _) = failure.underlyingError else {
                Issue.record("A rejected token was reported as \(failure.underlyingError).")
                return
            }
            statuses = failure.statuses
        }
        #expect(statuses.first?.errorMessage?.contains("Rejected credential") == true)
    }

    @Test func installationFailureReportsCompletedRegistrationsWithoutExposingTheToken() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await client.configureFailure(installation: 2)
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 3, token: "access-token")
        #expect(statuses.first?.registeredCount == 1)
        #expect(statuses.first?.errorMessage?.contains("[redacted]") == true)
        #expect(statuses.first?.errorMessage?.contains("short-lived-registration-token") == false)
        #expect(await client.installations.count == 2)
    }

    @Test func registrationCreatedByAFailedInstallerIsPreservedAndCounted() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await client.configureFailure(installation: 1, afterRegistration: true)
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 2, token: "access-token")
        #expect(statuses.first?.registeredCount == 1)
        #expect(statuses.first?.errorMessage == "Installation failed after registration.")
    }

    @Test func repeatedConfigurationFailuresReuseTheirOwnedDirectory() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await client.configurePendingFailures(count: 3)
        for _ in 0..<3 {
            let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
            #expect(statuses.first?.errorMessage == "Installation was interrupted.")
        }
        let requests = await client.installations
        #expect(requests.count == 3)
        #expect(Set(requests.map(\.runnerName)).count == 1)
        let runnersRoot = root.appending(path: "Library/XcodeRunnerKit/runners")
        #expect(try FileManager.default.contentsOfDirectory(atPath: runnersRoot.path(percentEncoded: false)).count == 1)
    }

    @Test func retryAfterRegistrationResumesTheSameRunnerWithoutRegisteringAnother() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await client.configurePendingFailures(count: 1, afterRegistration: true)
        let first = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(first.first?.registeredCount == 0)
        #expect(first.first?.errorMessage == "Installation was interrupted.")
        let retried = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(retried.first?.registeredCount == 1)
        #expect(retried.first?.errorMessage == nil)
        let requests = await client.installations
        #expect(requests.count == 2)
        #expect(Set(requests.map(\.runnerName)).count == 1)
        #expect(requests.allSatisfy { !$0.replaceRegistration })
        #expect(try await client.listRunners(repository: firstRepository, accessToken: "access-token").count == 1)
    }

    @Test func retryRecoversAnOfflineRemoteRegistrationCreatedBeforeLocalSettings() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await client.configurePendingFailures(count: 1, beforeLocalSettings: true)
        let first = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(first.first?.errorMessage == "Installation was interrupted.")
        let retried = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(retried.first?.registeredCount == 1)
        #expect(retried.first?.errorMessage == nil)
        let requests = await client.installations
        #expect(requests.map(\.replaceRegistration) == [false, true])
        #expect(Set(requests.map(\.runnerName)).count == 1)
        #expect(try await client.listRunners(repository: firstRepository, accessToken: "access-token").count == 1)
    }

    @Test(arguments: ["online", "busy"])
    func recoveryDoesNotReplaceAnOnlineOrBusyRemoteRunner(state: String) async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = RunnerProvisioner.runnerName(hostName: "CI Mac", repository: firstRepository, slot: 1)
        let directory = root.appending(path: "Library/XcodeRunnerKit/runners/\(name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try String(firstRepository.id).write(
            to: directory.appending(path: ".xcode-runner-installation"), atomically: true, encoding: .utf8
        )
        await client.addRemoteRunner(
            repository: firstRepository, identifier: 1, name: name, online: state == "online", busy: state == "busy"
        )
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(statuses.first?.errorMessage?.contains("must be offline and idle") == true)
        #expect(await client.installations.isEmpty)
    }

    @Test(arguments: ["", "2"])
    func directoriesWithoutMatchingInstallationOwnershipArePreserved(owner: String) async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = RunnerProvisioner.runnerName(hostName: "CI Mac", repository: firstRepository, slot: 1)
        let directory = root.appending(path: "Library/XcodeRunnerKit/runners/\(name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = directory.appending(path: "user-data")
        try Data("keep existing files".utf8).write(to: payload)
        if !owner.isEmpty {
            try owner.write(to: directory.appending(path: ".xcode-runner-installation"), atomically: true, encoding: .utf8)
        }
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(statuses.first?.registeredCount == 1)
        #expect(await client.installations.first?.runnerName != name)
        #expect(await client.installations.allSatisfy { !$0.replaceRegistration })
        #expect(try Data(contentsOf: payload) == Data("keep existing files".utf8))
    }

    @Test func anOwnedMarkerDoesNotAuthorizeResumingAnUnmatchedRegistration() async throws {
        let (root, client, provisioner) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = RunnerProvisioner.runnerName(hostName: "CI Mac", repository: firstRepository, slot: 1)
        try await client.addRunner(
            repository: firstRepository, identifier: 1, name: name, hosted: false, localIdentifier: 2
        )
        let directory = root.appending(path: "Library/XcodeRunnerKit/runners/\(name)")
        try String(firstRepository.id).write(
            to: directory.appending(path: ".xcode-runner-installation"), atomically: true, encoding: .utf8
        )
        let metadata = try Data(contentsOf: directory.appending(path: ".runner"))
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(statuses.first?.errorMessage?.contains("could not be matched") == true)
        #expect(await client.installations.isEmpty)
        #expect(try Data(contentsOf: directory.appending(path: ".runner")) == metadata)
    }

    @Test func realInstallerReceivesTokenOnStandardInputAndReportsRedactedFailures() async throws {
        let root = URL.temporaryDirectory.appending(path: "Runner installer \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = root.appending(path: "fake installer.sh")
        try """
        #!/bin/bash
        IFS= read -r token
        printf '%s' "$token" > "$HOME/token-input"
        printf '%s' "$XCODE_RUNNER_INSTALLATION_REPOSITORY_ID" > "$HOME/repository-id"
        printf '%s' "$XCODE_RUNNER_REPLACE_REGISTRATION" > "$HOME/replace-registration"
        printf '%s\\n' "$@" > "$HOME/installer-arguments"
        printf '%s' "$token" >&2
        exit 1
        """.write(to: installer, atomically: true, encoding: .utf8)
        let installation = HostInstallation(homeDirectory: root)
        let client = Client(installation: installation)
        let archive = root.appending(path: "verified runner.tar.gz")
        let provisioner = RunnerProvisioner(
            installation: installation, installerURL: installer, client: client,
            prepareArchive: { _ in archive }
        )
        let statuses = try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        #expect(try String(contentsOf: root.appending(path: "token-input"), encoding: .utf8) == "short-lived-registration-token")
        #expect(try String(contentsOf: root.appending(path: "repository-id"), encoding: .utf8) == String(firstRepository.id))
        #expect(try String(contentsOf: root.appending(path: "replace-registration"), encoding: .utf8) == "0")
        let arguments = try String(contentsOf: root.appending(path: "installer-arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.count == 5)
        #expect(arguments[0] == firstRepository.fullName)
        #expect(arguments[2] == archive.path(percentEncoded: false))
        #expect(arguments[3] == "xcode-runnerkit")
        #expect(arguments[4] == "test-checksum")
        #expect(statuses.first?.errorMessage?.contains("[redacted]") == true)
        #expect(statuses.first?.errorMessage?.contains("short-lived-registration-token") == false)
    }

    @Test func cancellingInstallerTerminatesItsChildrenAndReleasesTheirInheritedStorageLock() async throws {
        let root = URL.temporaryDirectory.appending(path: "Runner cancellation \(UUID().uuidString)")
        let installation = HostInstallation(homeDirectory: root)
        try FileManager.default.createDirectory(at: installation.hostRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = root.appending(path: "fake installer.sh")
        try #"exec python3 "$HOME/installer.py""#.write(to: installer, atomically: true, encoding: .utf8)
        try """
        import fcntl, json, os, signal, time
        from pathlib import Path
        root = Path.home()
        descriptor = os.open(root / 'Library/Application Support/XcodeRunnerKit/storage.lock', os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.set_inheritable(descriptor, True)
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            pending = root / 'child.pending'
            pending.write_text(json.dumps({'pid': os.getpid(), 'group': os.getpgrp()}))
            pending.replace(root / 'child.json')
        while True:
            time.sleep(1)
        """.write(to: root.appending(path: "installer.py"), atomically: true, encoding: .utf8)
        let client = Client(installation: installation)
        let archive = root.appending(path: "verified-runner.tar.gz")
        let provisioner = RunnerProvisioner(
            installation: installation, installerURL: installer, client: client, prepareArchive: { _ in archive }
        )
        let provisioning = Task {
            try await provisioner.reconcile(repositories: [firstRepository], capacity: 1, token: "access-token")
        }
        defer { provisioning.cancel() }
        let marker = root.appending(path: "child.json")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) }
        provisioning.cancel()
        struct Child: Decodable { let pid: Int32; let group: Int32 }
        let child = try JSONDecoder().decode(Child.self, from: Data(contentsOf: marker))
        #expect(child.group != getpgrp())
        func childIsRunning() -> Bool {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            return proc_pidinfo(child.pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size
                && info.pbsi_status != UInt32(SZOMB)
        }
        defer { if childIsRunning() { kill(child.pid, SIGKILL) } }
        // A surviving child keeps its output pipes open, so provisioning would never finish.
        // Wait for the child first: the suite time limit can cancel this wait, then the deferred kill runs.
        try await waitUntil { !childIsRunning() }
        _ = try await provisioning.value
        let descriptor = open(installation.hostRoot.appending(path: "storage.lock").path(percentEncoded: false), O_RDWR)
        defer { if descriptor >= 0 { close(descriptor) } }
        #expect(descriptor >= 0)
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    }

    @Test func checksumMismatchRejectsTheArchive() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "runner.tar.gz")
        try Data("abc".utf8).write(to: file)
        let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(throws: Never.self) { try RunnerProvisioner.verifyArchive(at: file, checksum: checksum) }
        #expect(throws: (any Error).self) { try RunnerProvisioner.verifyArchive(at: file, checksum: String(repeating: "0", count: 64)) }
    }

    @Test func runnerNamesAreStableAndDistinguishRepositoryOwners() {
        let first = RunnerProvisioner.runnerName(hostName: "CI Mac", repository: firstRepository, slot: 1)
        #expect(first == RunnerProvisioner.runnerName(hostName: "CI Mac", repository: firstRepository, slot: 1))
        #expect(first != RunnerProvisioner.runnerName(
            hostName: "CI Mac", repository: GitHubRepository(id: 3, fullName: "another/First"), slot: 1
        ))
        #expect(!first.contains(" "))
        #expect(!first.contains("/"))
    }
}
