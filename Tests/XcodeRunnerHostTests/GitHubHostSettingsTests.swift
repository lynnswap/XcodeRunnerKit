import Foundation
import Testing
import XcodeRunnerKit
@testable import XcodeRunnerHost

@MainActor
struct GitHubHostSettingsTests {
    @Test(arguments: [true, false])
    func savedRepositoryIdentitySurvivesRenameAndOldNameReuse(isStillAccessible: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let saved = GitHubRepository(id: 1, fullName: "owner/Previous")
        try GitHubHostConfiguration(clientID: "app", repositories: [saved])
            .save(to: installation.hostRoot.appending(path: "github-host.json"))
        let directory = installation.runnersRoot.appending(path: "existing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"agentId":1,"agentName":"existing","gitHubUrl":"https://github.com/owner/Renamed"}"#.utf8)
            .write(to: directory.appending(path: ".runner"))
        try Data().write(to: directory.appending(path: ".xcode-runner-host"))
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
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
        let pool = try HostExecutionPool(directory: installation.poolDirectory, initialCapacity: 1)
        try await pool.updateMaximumConcurrentJobs(to: 1)
        let model = GitHubHostSettings(
            installation: installation, pool: pool, client: client,
            authentication: GitHubAuthentication(client: client, store: store)
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
        try GitHubHostConfiguration(clientID: "app", repositories: [repository])
            .save(to: installation.hostRoot.appending(path: "github-host.json"))
        let directory = installation.runnersRoot.appending(path: "existing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"agentId":1,"agentName":"existing","gitHubUrl":"https://github.com/owner/Project"}"#.utf8)
            .write(to: directory.appending(path: ".runner"))
        try Data().write(to: directory.appending(path: ".xcode-runner-host"))
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
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
        let pool = try HostExecutionPool(directory: installation.poolDirectory, initialCapacity: 1)
        try await pool.updateMaximumConcurrentJobs(to: 1)
        let model = GitHubHostSettings(
            installation: installation, pool: pool, client: client,
            authentication: GitHubAuthentication(client: client, store: store)
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

    @Test func createdAppCanBeSavedAgainAfterASettingsWriteFailure() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let app = CreatedGitHubApp(
            clientID: "app", slug: "host-app", clientSecret: "secret",
            callbackURL: URL(string: "http://127.0.0.1:12345/callback")!
        )
        let appStore = MemoryGitHubCredentialStore()
        let client = GitHubClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let authentication = GitHubAuthentication(client: client, store: MemoryGitHubCredentialStore(), appStore: appStore)
        let model = GitHubHostSettings(
            installation: installation, pool: try HostExecutionPool(directory: installation.poolDirectory, initialCapacity: 4),
            client: client, authentication: authentication
        )
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await model.storeCreatedApp(app) }
        #expect(model.hasPendingApp)
        #expect(try await authentication.appClientID() == app.clientID)
        try FileManager.default.removeItem(at: record)
        try await model.storeCreatedApp(app)
        #expect(!model.hasPendingApp)
        let saved = try GitHubHostConfiguration.load(from: record)
        #expect(saved.clientID == app.clientID)
        #expect(saved.appSlug == app.slug)
        #expect(saved.callbackURL == app.callbackURL)
        #expect(String(decoding: try Data(contentsOf: record), as: UTF8.self).contains("secret") == false)
    }

    @Test func revocationDuringProvisioningMakesSignInAvailableAgain() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        try GitHubHostConfiguration(clientID: "app", repositories: [repository])
            .save(to: installation.hostRoot.appending(path: "github-host.json"))
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
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
        let pool = try HostExecutionPool(directory: installation.poolDirectory, initialCapacity: 4)
        try await pool.updateMaximumConcurrentJobs(to: 24)
        let model = GitHubHostSettings(
            installation: installation, pool: pool, client: client,
            authentication: GitHubAuthentication(client: client, store: store)
        )
        await model.restore()
        #expect(model.account != nil)
        model.storageIsReady = true
        await model.synchronize()
        #expect(model.account == nil)
        #expect(model.errorMessage?.contains("Sign in") == true)
        #expect(model.runnerStatuses.first?.requiresAuthentication == true)
    }

    @Test(arguments: [true, false])
    func expirationOrRevocationMakesSignInAvailableAgain(expired: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        try GitHubHostConfiguration(clientID: "app").save(to: installation.hostRoot.appending(path: "github-host.json"))
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "expired",
            refreshToken: "refresh", expiresAt: expired ? Date.distantPast : Date.distantFuture,
            refreshExpiresAt: expired ? Date.distantPast : Date.distantFuture
        )))
        let client = GitHubClient(transport: { request in
            (Data(#"{"message":"Bad credentials"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        let model = GitHubHostSettings(
            installation: installation, pool: try HostExecutionPool(directory: installation.poolDirectory, initialCapacity: 4),
            client: client, authentication: GitHubAuthentication(client: client, store: store)
        )
        await model.restore()
        #expect(model.account == nil)
        #expect(model.clientIDInput == "app")
        #expect(model.errorMessage != nil)
    }

    @Test func selectionSurvivesRestartAndRemainsEditableWhenGitHubIsUnavailable() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let configuration = GitHubHostConfiguration(clientID: "app", appSlug: "host-app", repositories: [repository])
        try configuration.save(to: record)
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "token",
            refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
        )))
        let client = GitHubClient(transport: { request in
            (Data(#"{"message":"Network unavailable"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        let model = GitHubHostSettings(
            installation: installation, pool: try HostExecutionPool(directory: installation.poolDirectory, initialCapacity: 4),
            client: client, authentication: GitHubAuthentication(client: client, store: store)
        )
        await model.restore()
        #expect(model.account?.login == "owner")
        #expect(model.errorMessage?.contains("Network unavailable") == true)
        #expect(model.selectableRepositories == [repository])
        #expect(model.selectedRepositoryIDs == [repository.id])
        model.selectedRepositoryIDs = []
        try model.saveSelection()
        #expect(try GitHubHostConfiguration.load(from: record).repositories.isEmpty)
    }

    @Test func applyingLocalLimitPreservesRegistrationSelectionWhileSignedOut() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        try GitHubHostConfiguration(clientID: "app", repositories: [repository]).save(to: record)
        let model = try HostSettingsModel(installation: installation)
        model.github.storageIsReady = true
        await model.refreshPoolStatus()
        model.capacityInput = "24"
        await model.applyCapacity()
        #expect(model.saveError == nil)
        #expect(model.poolStatus?.maximumConcurrentJobs == 24)
        #expect(model.github.errorMessage?.contains("Sign in") == true)
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [repository])
    }
}
