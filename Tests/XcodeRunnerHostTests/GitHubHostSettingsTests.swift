import Foundation
import Testing
import XcodeRunnerHostSupport
import XcodeRunnerKit
@testable import XcodeRunnerHost

private struct RejectingGitHubCredentialWrites: GitHubCredentialStore {
    let store: MemoryGitHubCredentialStore
    func read() -> Data? { store.read() }
    func write(_ data: Data) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove() { store.remove() }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct GitHubHostSettingsTests {
    private func waitForSignIn(_ model: GitHubHostSettings) async throws {
        try await waitUntil { !model.isConnecting }
        await model.shutDown()
    }

    @Test(arguments: [false, true])
    func unsuccessfulAppSignInKeepsTheSavedAppAndRepositorySelection(isCancelled: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let previous = GitHubHostConfiguration(clientID: "previous-app", appSlug: "previous-host", repositories: [repository])
        try previous.save(to: record)
        let client = GitHubClient(transport: { request in
            if isCancelled { throw CancellationError() }
            let body = #"{"error":"incorrect_client_credentials","error_description":"The Client ID is incorrect."}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: GitHubAuthentication(client: client, store: MemoryGitHubCredentialStore()),
            openURL: { _ in Issue.record("Authorization should fail before opening a browser."); return false }
        )
        model.clientIDInput = "candidate-app"
        model.appSlugInput = "candidate-host"
        model.signIn()
        try await waitForSignIn(model)
        #expect(try GitHubHostConfiguration.load(from: record) == previous)
        #expect(model.selectedRepositoryIDs == [repository.id])
        #expect(model.selectableRepositories == [repository])
        #expect(model.account == nil)
        #expect((model.errorMessage == nil) == isCancelled)
    }

    @Test(arguments: [true, false])
    func authenticatedAppChoiceIsAppliedOnlyAfterItsSettingsAreSaved(canSaveSettings: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let installation = HostInstallation(homeDirectory: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installation.hostRoot.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: root)
        }
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let previous = GitHubHostConfiguration(clientID: "previous-app", appSlug: "previous-host", repositories: [repository])
        try previous.save(to: record)
        let transport = GitHubTestTransport([
            .init(path: "/login/device/code", body: #"{"device_code":"device","user_code":"USER-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"candidate-token"}"#),
            .init(path: "/user", body: #"{"id":1,"login":"owner"}"#),
        ] + (canSaveSettings ? [.init(path: "/user/installations", body: #"{"installations":[]}"#)] : []))
        let client = await transport.client
        let authentication = GitHubAuthentication(client: client, store: MemoryGitHubCredentialStore(), sleep: { _ in })
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: authentication, openURL: { _ in true }
        )
        model.clientIDInput = "candidate-app"
        model.appSlugInput = " candidate-host "
        if !canSaveSettings {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installation.hostRoot.path(percentEncoded: false))
        }
        model.signIn()
        try await waitForSignIn(model)
        #expect(try await authentication.account(clientID: "candidate-app")?.login == "owner")
        let saved = try GitHubHostConfiguration.load(from: record)
        if canSaveSettings {
            #expect(saved.clientID == "candidate-app")
            #expect(saved.appSlug == "candidate-host")
            #expect(saved.repositories.isEmpty)
            #expect(model.selectedRepositoryIDs.isEmpty)
            #expect(model.account?.login == "owner")
            #expect(model.errorMessage == nil)
        } else {
            #expect(saved == previous)
            #expect(model.selectedRepositoryIDs == [repository.id])
            #expect(model.account == nil)
            #expect(model.errorMessage?.contains("GitHub sign-in succeeded") == true)
            #expect(model.errorMessage?.contains("previous repository settings are retained") == true)
        }
    }

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
        let pool = HostExecutionPool(directory: installation.poolDirectory)
        try await pool.configure(maximumConcurrentJobs: 1)
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
        let pool = HostExecutionPool(directory: installation.poolDirectory)
        try await pool.configure(maximumConcurrentJobs: 1)
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
        let installation = HostInstallation(homeDirectory: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installation.hostRoot.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: root)
        }
        let record = installation.hostRoot.appending(path: "github-host.json")
        let previous = GitHubHostConfiguration(clientID: "previous-app", appSlug: "previous-host")
        try previous.save(to: record)
        let app = CreatedGitHubApp(
            clientID: "app", slug: "host-app", clientSecret: "secret",
            callbackURL: URL(string: "http://127.0.0.1:12345/callback")!
        )
        let appStore = MemoryGitHubCredentialStore()
        let transport = GitHubTestTransport([
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"previous-fresh","refresh_token":"previous-rotated","expires_in":28800,"refresh_token_expires_in":3600}"#),
            .init(path: "/user/installations", body: #"{"installations":[]}"#),
        ])
        let client = await transport.client
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: previous.clientID, account: GitHubAccount(id: 1, login: "owner"), accessToken: "previous-expired",
            refreshToken: "previous-refresh", expiresAt: Date.distantPast, refreshExpiresAt: Date.distantFuture
        )))
        let authentication = GitHubAuthentication(client: client, store: store, appStore: appStore)
        try await authentication.configureTestApp(clientID: previous.clientID, clientSecret: "previous-secret")
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: authentication
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installation.hostRoot.path(percentEncoded: false))
        await #expect(throws: (any Error).self) { try await model.storeCreatedApp(app) }
        #expect(model.hasPendingApp)
        #expect(model.clientIDInput == previous.clientID)
        #expect(try GitHubHostConfiguration.load(from: record) == previous)
        let restoredAuthentication = GitHubAuthentication(client: client, store: store, appStore: appStore)
        #expect(try await restoredAuthentication.accessToken(clientID: previous.clientID) == "previous-fresh")
        let refreshRequest = try #require(await transport.requests.first)
        let body = try #require(refreshRequest.httpBody)
        #expect(URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems?.contains(
            URLQueryItem(name: "client_secret", value: "previous-secret")
        ) == true)
        let restored = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: restoredAuthentication
        )
        await restored.restore()
        #expect(restored.account?.login == "owner")
        #expect(restored.hasPendingApp)
        let recovered = try #require(await restoredAuthentication.pendingCreatedApp())
        #expect(recovered.clientID == app.clientID)
        #expect(recovered.slug == app.slug)
        #expect(recovered.callbackURL == app.callbackURL)
        #expect(recovered.clientSecret == app.clientSecret)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installation.hostRoot.path(percentEncoded: false))
        try await restored.storeCreatedApp(recovered)
        #expect(!restored.hasPendingApp)
        #expect(try await restoredAuthentication.pendingCreatedApp() == nil)
        let saved = try GitHubHostConfiguration.load(from: record)
        #expect(saved.clientID == app.clientID)
        #expect(saved.appSlug == app.slug)
        #expect(saved.callbackURL == app.callbackURL)
        #expect(String(decoding: try Data(contentsOf: record), as: UTF8.self).contains("secret") == false)
    }

    @Test func appKeychainFailureLeavesTheSavedConfigurationAndSecretUnchanged() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let previous = GitHubHostConfiguration(clientID: "previous-app", appSlug: "previous-host")
        try previous.save(to: record)
        let client = GitHubClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let appStore = MemoryGitHubCredentialStore()
        let store = MemoryGitHubCredentialStore()
        let original = GitHubAuthentication(client: client, store: store, appStore: appStore)
        try await original.configureTestApp(clientID: previous.clientID, clientSecret: "previous-secret")
        let originalData = try #require(appStore.read())
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: GitHubAuthentication(
                client: client, store: store, appStore: RejectingGitHubCredentialWrites(store: appStore)
            )
        )
        let app = CreatedGitHubApp(
            clientID: "next-app", slug: "next-host", clientSecret: "next-secret",
            callbackURL: URL(string: "http://127.0.0.1:12345/callback")!
        )
        await #expect(throws: CocoaError.self) { try await model.storeCreatedApp(app) }
        #expect(try GitHubHostConfiguration.load(from: record) == previous)
        #expect(model.clientIDInput == previous.clientID)
        #expect(appStore.read() == originalData)
        #expect(model.hasPendingApp)
    }

    @Test func firstCreatedAppCanBeRecoveredBeforeAnyConfigurationWasSaved() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let app = CreatedGitHubApp(
            clientID: "app", slug: "host-app", clientSecret: "secret",
            callbackURL: URL(string: "http://127.0.0.1:12345/callback")!
        )
        let appStore = MemoryGitHubCredentialStore()
        let client = GitHubClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let authentication = GitHubAuthentication(client: client, store: MemoryGitHubCredentialStore(), appStore: appStore)
        try await authentication.stageCreatedApp(app)
        let restoredAuthentication = GitHubAuthentication(client: client, store: MemoryGitHubCredentialStore(), appStore: appStore)
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: restoredAuthentication
        )
        await model.restore()
        #expect(model.hasPendingApp)
        #expect(model.account == nil)
        #expect(model.clientIDInput.isEmpty)
        #expect(try await restoredAuthentication.pendingCreatedApp()?.callbackURL == app.callbackURL)
    }

    @Test func pendingSecretCanAuthorizeWhenItsActivationCouldNotBeSaved() async throws {
        let app = CreatedGitHubApp(
            clientID: "next-app", slug: "next-host", clientSecret: "next-secret",
            callbackURL: URL(string: "http://127.0.0.1:12345/callback")!
        )
        let transport = GitHubTestTransport([
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"next-token"}"#),
            .init(path: "/user", body: #"{"id":1,"login":"owner"}"#),
        ])
        let client = await transport.client
        let appStore = MemoryGitHubCredentialStore()
        let store = MemoryGitHubCredentialStore()
        let authentication = GitHubAuthentication(client: client, store: store, appStore: appStore)
        try await authentication.configureTestApp(clientID: "previous-app", clientSecret: "previous-secret")
        try await authentication.stageCreatedApp(app)
        let failing = GitHubAuthentication(client: client, store: store, appStore: RejectingGitHubCredentialWrites(store: appStore))
        await #expect(throws: CocoaError.self) { try await failing.activatePendingApp(clientID: app.clientID) }
        let restored = GitHubAuthentication(client: client, store: store, appStore: appStore)
        let account = try await restored.completeWebAuthorization(
            clientID: app.clientID, code: "code", redirectURI: app.callbackURL, codeVerifier: "verifier"
        )
        #expect(account.login == "owner")
        #expect(try await restored.pendingCreatedApp()?.clientID == app.clientID)
        let request = try #require(await transport.requests.first)
        let body = try #require(request.httpBody)
        #expect(URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems?.contains(
            URLQueryItem(name: "client_secret", value: app.clientSecret)
        ) == true)
    }

    @Test func retryingPendingActivationPreservesAnExplicitAppChoiceAndItsRepositories() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let app = CreatedGitHubApp(
            clientID: "app", slug: "host-app", clientSecret: "secret",
            callbackURL: URL(string: "http://127.0.0.1:12345/callback")!
        )
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let saved = GitHubHostConfiguration(
            clientID: app.clientID, appSlug: app.slug, callbackURL: app.callbackURL, repositories: [repository]
        )
        try saved.save(to: record)
        let client = GitHubClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let appStore = MemoryGitHubCredentialStore()
        let authentication = GitHubAuthentication(client: client, store: MemoryGitHubCredentialStore(), appStore: appStore)
        try await authentication.stageCreatedApp(app)
        let model = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: authentication
        )
        await model.restore()
        #expect(model.hasPendingApp)
        #expect(model.selectedRepositoryIDs == [repository.id])
        #expect(try GitHubHostConfiguration.load(from: record) == saved)
        try await model.storeCreatedApp(app)
        #expect(model.selectedRepositoryIDs == [repository.id])
        #expect(try GitHubHostConfiguration.load(from: record) == saved)
        #expect(!model.hasPendingApp)
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
        let pool = HostExecutionPool(directory: installation.poolDirectory)
        try await pool.configure(maximumConcurrentJobs: 24)
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
        // The statuses from the rejected run stay visible after the refresh fails.
        #expect(model.runnerStatuses.first?.errorMessage?.contains("Bad credentials") == true)
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
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
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
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            client: client, authentication: GitHubAuthentication(client: client, store: store)
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
        try GitHubHostConfiguration(clientID: "app", repositories: [repository]).save(to: record)
        let model = HostSettingsModel(installation: installation)
        model.github.storageIsReady = true
        await model.refreshPoolStatus()
        model.capacityInput = "24"
        await model.applyPoolConfiguration()
        #expect(model.saveError == nil)
        #expect(model.poolStatus?.configuration.maximumConcurrentJobs == 24)
        #expect(model.github.errorMessage?.contains("Sign in") == true)
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [repository])
    }
}
