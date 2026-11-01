import Foundation
import Testing
import XcodeRunnerHostSupport
import XcodeRunnerKit
@testable import XcodeRunnerHostApp

@MainActor @Suite(.timeLimit(.minutes(1)))
struct GitHubHostSettingsTests {
    private func waitForSignIn(_ model: GitHubHostSettings) async throws {
        try await waitUntil { !model.isConnecting }
        await model.shutDown()
    }

    @Test(arguments: [false, true])
    func unsuccessfulSignInKeepsTheRepositorySelection(isCancelled: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let previous = GitHubHostConfiguration(repositories: [repository])
        try previous.save(to: record)
        let client = GitHubClient(transport: { request in
            if isCancelled { throw CancellationError() }
            let body = #"{"error":"incorrect_client_credentials","error_description":"The Client ID is incorrect."}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: GitHubAuthentication(clientID: "app", client: client, store: MemorySecretStore()),
            openURL: { _ in Issue.record("Authorization should fail before opening a browser."); return false }
        )
        model.signIn()
        try await waitForSignIn(model)
        #expect(try GitHubHostConfiguration.load(from: record) == previous)
        #expect(model.selectedRepositoryIDs == [repository.id])
        #expect(model.selectableRepositories == [repository])
        #expect(model.account == nil)
        #expect((model.errorMessage == nil) == isCancelled)
    }

    @Test func deviceSignInOpensGitHubAndKeepsTheRepositorySelection() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let previous = GitHubHostConfiguration(repositories: [repository])
        try previous.save(to: record)
        let transport = GitHubTestTransport([
            .init(path: "/login/device/code", body: #"{"device_code":"device","user_code":"USER-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"token"}"#),
            .init(path: "/user", body: #"{"id":1,"login":"owner"}"#),
            .init(path: "/user/installations", body: #"{"installations":[]}"#),
        ])
        let client = await transport.client
        let authentication = GitHubAuthentication(clientID: "app", client: client, store: MemorySecretStore(), sleep: { _ in })
        var opened: [URL] = []
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            app: GitHubApp(clientID: "app", slug: "host-app"), client: client, authentication: authentication,
            openURL: { opened.append($0); return true }
        )
        model.signIn()
        try await waitForSignIn(model)
        #expect(model.account?.login == "owner")
        #expect(model.errorMessage == nil)
        #expect(try await authentication.account()?.login == "owner")
        #expect(try GitHubHostConfiguration.load(from: record) == previous)
        #expect(model.selectedRepositoryIDs == [repository.id])
        let body = try #require(await transport.requests.first?.httpBody)
        #expect(URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems?.contains(
            URLQueryItem(name: "client_id", value: "app")
        ) == true)
        model.installApp()
        #expect(opened == [
            URL(string: "https://github.com/login/device")!,
            URL(string: "https://github.com/apps/host-app/installations/new")!,
        ])
    }

    @Test(arguments: [true, false])
    func savedRepositoryIdentitySurvivesRenameAndOldNameReuse(isStillAccessible: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let saved = GitHubRepository(id: 1, fullName: "owner/Previous")
        try GitHubHostConfiguration(repositories: [saved])
            .save(to: installation.hostRoot.appending(path: "github-host.json"))
        let directory = installation.runnersRoot.appending(path: "existing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"agentId":1,"agentName":"existing","gitHubUrl":"https://github.com/owner/Renamed"}"#.utf8)
            .write(to: directory.appending(path: ".runner"))
        try Data().write(to: directory.appending(path: ".xcode-runner-host"))
        let store = MemorySecretStore()
        try store.write(JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "token",
            refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
        )))
        let accessible = isStillAccessible
            ? #"{"repositories":[{"id":1,"full_name":"owner/Renamed"},{"id":2,"full_name":"owner/Previous"}]}"#
            : #"{"repositories":[{"id":2,"full_name":"owner/Previous"}]}"#
        let listing: [GitHubTestTransport.Reply] = [
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#),
            .init(path: "/user/installations/10/repositories", body: accessible),
        ]
        let transport = GitHubTestTransport(listing + listing + (isStillAccessible ? [
            .init(path: "/repos/owner/Renamed/actions/runners", body: #"{"runners":[{"id":1,"name":"existing","status":"online","busy":false,"labels":[]}]}"#),
        ] : []))
        let client = await transport.client
        let pool = HostExecutionPool(directory: installation.poolDirectory)
        try await pool.configure(maximumConcurrentJobs: 1)
        let model = GitHubHostSettings(
            installation: installation, pool: pool, client: client,
            authentication: GitHubAuthentication(clientID: "app", client: client, store: store)
        )
        await model.restore()
        model.storageIsReady = true
        await model.synchronize()
        let status = try #require(model.runnerStatuses.first)
        #expect(status.repository.id == saved.id)
        #expect(status.repository.fullName == (isStillAccessible ? "owner/Renamed" : saved.fullName))
        #expect(status.onlineCount == (isStillAccessible ? 1 : 0))
        #expect((status.errorMessage == nil) == isStillAccessible)
        #expect(await transport.requests.allSatisfy { $0.url?.path.hasPrefix("/repos/owner/Previous/") == false })
    }

    @Test func tokenExpirationDuringProvisioningRefreshesWithoutSigningOut() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        try GitHubHostConfiguration(repositories: [repository])
            .save(to: installation.hostRoot.appending(path: "github-host.json"))
        let directory = installation.runnersRoot.appending(path: "existing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"agentId":1,"agentName":"existing","gitHubUrl":"https://github.com/owner/Project"}"#.utf8)
            .write(to: directory.appending(path: ".runner"))
        try Data().write(to: directory.appending(path: ".xcode-runner-host"))
        let store = MemorySecretStore()
        try store.write(JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "expiring",
            refreshToken: "refresh", expiresAt: Date.distantFuture, refreshExpiresAt: Date.distantFuture
        )))
        let transport = GitHubTestTransport([
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#),
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#),
            .init(path: "/repos/owner/Project/actions/runners", body: #"{"message":"Bad credentials"}"#, status: 401),
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"fresh","refresh_token":"new-refresh","expires_in":28800,"refresh_token_expires_in":3600}"#),
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#),
            .init(path: "/repos/owner/Project/actions/runners", body: #"{"runners":[{"id":1,"name":"existing","status":"online","busy":false,"labels":[]}]}"#),
        ])
        let client = await transport.client
        let pool = HostExecutionPool(directory: installation.poolDirectory)
        try await pool.configure(maximumConcurrentJobs: 1)
        let model = GitHubHostSettings(
            installation: installation, pool: pool, client: client,
            authentication: GitHubAuthentication(clientID: "app", client: client, store: store)
        )
        await model.restore()
        model.storageIsReady = true
        await model.synchronize()
        #expect(model.account?.login == "owner")
        #expect(model.errorMessage == nil)
        #expect(model.runnerStatuses.first?.onlineCount == 1)
        let saved = try JSONDecoder().decode(GitHubCredentials.self, from: #require(store.read()))
        #expect(saved.accessToken == "fresh")
        #expect(saved.refreshToken == "new-refresh")
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func revocationDuringProvisioningMakesSignInAvailableAgain() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        try GitHubHostConfiguration(repositories: [repository])
            .save(to: installation.hostRoot.appending(path: "github-host.json"))
        let store = MemorySecretStore()
        try store.write(JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "revoked",
            refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
        )))
        let client = GitHubClient(transport: { request in
            let body: String
            let status: Int
            switch request.url?.path {
            case "/user/installations":
                body = #"{"installations":[{"id":10}]}"#
                status = 200
            case "/user/installations/10/repositories":
                body = #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#
                status = 200
            default:
                body = #"{"message":"Bad credentials"}"#
                status = 401
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let pool = HostExecutionPool(directory: installation.poolDirectory)
        try await pool.configure(maximumConcurrentJobs: 24)
        let model = GitHubHostSettings(
            installation: installation, pool: pool, client: client,
            authentication: GitHubAuthentication(clientID: "app", client: client, store: store)
        )
        await model.restore()
        #expect(model.account != nil)
        model.storageIsReady = true
        await model.synchronize()
        #expect(model.account == nil)
        #expect(model.errorMessage?.contains("Sign in") == true)
        // The statuses from the rejected run stay visible after the refresh fails.
        #expect(model.runnerStatuses.first?.errorMessage?.contains("Bad credentials") == true)
    }

    @Test func deselectingARepositoryRemovesItsRunnersOnceSignedIn() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Unlinked")
        try GitHubHostConfiguration(repositories: [repository]).save(to: record)
        let directory = installation.runnersRoot.appending(path: "existing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"agentId":7,"agentName":"existing","gitHubUrl":"https://github.com/owner/Unlinked"}"#.utf8)
            .write(to: directory.appending(path: ".runner"))
        try Data().write(to: directory.appending(path: ".xcode-runner-host"))
        let store = MemorySecretStore()
        try store.write(JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "token",
            refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
        )))
        let listing: [GitHubTestTransport.Reply] = [
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Unlinked"}]}"#),
        ]
        let runners = GitHubTestTransport.Reply(
            path: "/repos/owner/Unlinked/actions/runners",
            body: #"{"runners":[{"id":7,"name":"existing","status":"online","busy":false,"labels":[]}]}"#
        )
        let transport = GitHubTestTransport(listing + listing + [
            runners, runners, .init(path: "/repos/owner/Unlinked/actions/runners/7", body: "", status: 204),
        ])
        let client = await transport.client
        let pool = HostExecutionPool(directory: installation.poolDirectory)
        try await pool.configure(maximumConcurrentJobs: 1)
        let model = GitHubHostSettings(
            installation: installation, pool: pool, client: client,
            authentication: GitHubAuthentication(clientID: "app", client: client, store: store)
        )
        model.storageIsReady = true

        // Before the credentials are restored, removing the runners waits for sign-in.
        #expect(try await model.updateRepositorySelection([])?.contains("Sign in") == true)
        #expect(try !RunnerDirectory(url: directory).isRemoved())
        #expect(try GitHubHostConfiguration.load(from: record).unlinkedRepositories == [repository])

        await model.restore()
        await model.synchronize()
        #expect(await transport.requests.last?.httpMethod == "DELETE")
        #expect(try RunnerDirectory(url: directory).isRemoved())
        #expect(model.runnerStatuses.isEmpty)
        #expect(try GitHubHostConfiguration.load(from: record).unlinkedRepositories.isEmpty)
    }

    @Test(arguments: [true, false])
    func expirationOrRevocationMakesSignInAvailableAgain(expired: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        try GitHubHostConfiguration().save(to: installation.hostRoot.appending(path: "github-host.json"))
        let store = MemorySecretStore()
        try store.write(JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "expired",
            refreshToken: "refresh", expiresAt: expired ? Date.distantPast : Date.distantFuture,
            refreshExpiresAt: expired ? Date.distantPast : Date.distantFuture
        )))
        let client = GitHubClient(transport: { request in
            (Data(#"{"message":"Bad credentials"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: GitHubAuthentication(clientID: "app", client: client, store: store)
        )
        await model.restore()
        #expect(model.account == nil)
        #expect(model.errorMessage != nil)
    }

    @Test func selectionSurvivesRestartAndRemainsEditableWhenGitHubIsUnavailable() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        try FileManager.default.createDirectory(at: installation.hostRoot, withIntermediateDirectories: true)
        try Data(#"{"clientID":"previous-app","appSlug":"previous-host","repositories":[{"id":1,"full_name":"owner/Project"}]}"#.utf8)
            .write(to: record)
        let store = MemorySecretStore()
        try store.write(JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "token",
            refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
        )))
        let client = GitHubClient(transport: { request in
            (Data(#"{"message":"Network unavailable"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: GitHubAuthentication(clientID: "app", client: client, store: store)
        )
        await model.restore()
        #expect(model.account?.login == "owner")
        #expect(model.errorMessage?.contains("Network unavailable") == true)
        #expect(model.selectableRepositories == [repository])
        #expect(model.selectedRepositoryIDs == [repository.id])
        model.selectedRepositoryIDs = []
        try model.saveSelection(model.selectedRepositoryIDs)
        #expect(try GitHubHostConfiguration.load(from: record).repositories.isEmpty)
    }

    @Test func applyingLocalLimitPreservesRegistrationSelectionWhileSignedOut() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        try GitHubHostConfiguration(repositories: [repository]).save(to: record)
        let model = HostSettingsModel(installation: installation)
        model.github.storageIsReady = true
        await model.refreshPoolStatus()
        model.poolDraft.capacityInput = "24"
        await model.applyPoolConfiguration()
        #expect(model.saveError == nil)
        #expect(model.poolStatus?.configuration.maximumConcurrentJobs == 24)
        #expect(model.github.errorMessage?.contains("Sign in") == true)
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [repository])
    }
}
