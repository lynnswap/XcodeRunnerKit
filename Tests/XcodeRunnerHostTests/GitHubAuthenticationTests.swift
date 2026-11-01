import Foundation
import Synchronization
import Testing
@testable import XcodeRunnerHostApp

final class MemoryGitHubCredentialStore: GitHubCredentialStore, Sendable {
    private let value = Mutex<(data: Data?, writes: Int)>((nil, 0))
    private let onRead: (@Sendable () -> Void)?

    init(onRead: (@Sendable () -> Void)? = nil) { self.onRead = onRead }

    var writeCount: Int { value.withLock { $0.writes } }
    func read() -> Data? {
        let data = value.withLock { $0.data }
        onRead?()
        return data
    }
    func write(_ data: Data) { value.withLock { $0.data = data; $0.writes += 1 } }
    func remove() { value.withLock { $0.data = nil } }
}

private actor GitHubPollSleeps {
    private(set) var intervals: [TimeInterval] = []
    func record(_ interval: TimeInterval) { intervals.append(interval) }
}

struct GitHubAuthenticationTests {
    @Test func deviceFlowWaitsForAuthorizationAndHonorsSlowDown() async throws {
        let transport = GitHubTestTransport([
            .init(path: "/login/oauth/access_token", body: #"{"error":"authorization_pending"}"#),
            .init(path: "/login/oauth/access_token", body: #"{"error":"slow_down","interval":10}"#),
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"access","refresh_token":"refresh","expires_in":28800,"refresh_token_expires_in":15897600}"#),
            .init(path: "/user", body: #"{"id":1,"login":"owner"}"#),
        ])
        let store = MemoryGitHubCredentialStore()
        let sleeps = GitHubPollSleeps()
        let now = Date()
        let authentication = GitHubAuthentication(
            clientID: "app", client: await transport.client, store: store, sleep: { await sleeps.record($0) }, now: { now }
        )
        let account = try await authentication.finish(GitHubDeviceAuthorization(
            deviceCode: "device", userCode: "USER-CODE", verificationURI: URL(string: "https://github.com/login/device")!,
            expiresAt: now.addingTimeInterval(900), interval: 5
        ))
        #expect(account == GitHubAccount(id: 1, login: "owner"))
        #expect(await sleeps.intervals == [5, 5, 10])
        #expect(try await authentication.accessToken() == "access")
        let credentials = try JSONDecoder().decode(GitHubCredentials.self, from: #require(store.read()))
        #expect(credentials.refreshToken == "refresh")
        #expect(credentials.expiresAt == now.addingTimeInterval(28800))
        let requests = await transport.requests
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(String(data: try #require(requests[0].httpBody), encoding: .utf8)?.contains("client_secret") == false)
    }

    @Test func refreshSendsOnlyTheClientIDAndRefreshToken() async throws {
        let now = Date()
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "expired",
            refreshToken: "refresh+&value", expiresAt: now.addingTimeInterval(-1), refreshExpiresAt: now.addingTimeInterval(3600)
        )))
        let transport = GitHubTestTransport([
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"refresh_token_expires_in":3600}"#),
        ])
        let authentication = GitHubAuthentication(clientID: "app", client: await transport.client, store: store, now: { now })
        #expect(try await authentication.accessToken() == "new-access")
        let body = try #require(await transport.requests.first?.httpBody)
        let refresh = try #require(URLComponents(string: "?" + String(decoding: body, as: UTF8.self)))
        #expect(refresh.queryItems?.sorted { $0.name < $1.name } == [
            URLQueryItem(name: "client_id", value: "app"),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: "refresh+&value"),
        ])
        let credentials = try JSONDecoder().decode(GitHubCredentials.self, from: #require(store.read()))
        #expect(credentials.refreshToken == "new-refresh")
        #expect(credentials.clientID == "app")
        try await authentication.signOut()
        #expect(try await authentication.account() == nil)
    }

    @Test func expiredRefreshTokenRequiresSignInWithoutMakingARequest() async throws {
        let now = Date()
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "expired",
            refreshToken: "expired-refresh", expiresAt: now.addingTimeInterval(-3600), refreshExpiresAt: now.addingTimeInterval(-1)
        )))
        let transport = GitHubTestTransport([])
        let authentication = GitHubAuthentication(clientID: "app", client: await transport.client, store: store, now: { now })
        await #expect(throws: GitHubError.self) { try await authentication.accessToken() }
        #expect(await transport.requests.isEmpty)
    }

    @Test func credentialsSavedForAnotherAppDoNotSignIn() async throws {
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: "previous-app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "access",
            refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
        )))
        let transport = GitHubTestTransport([])
        let authentication = GitHubAuthentication(clientID: "next-app", client: await transport.client, store: store)
        #expect(try await authentication.account() == nil)
        await #expect(throws: GitHubError.self) { try await authentication.accessToken() }
        #expect(await transport.requests.isEmpty)
    }

    @Test func delayedRejectionReusesTheTokenAlreadyRefreshedByAnotherCaller() async throws {
        let now = Date()
        let store = MemoryGitHubCredentialStore()
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "original",
            refreshToken: "refresh", expiresAt: now.addingTimeInterval(3600), refreshExpiresAt: now.addingTimeInterval(7200)
        )))
        let transport = GitHubTestTransport([
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"fresh","refresh_token":"fresh-refresh","expires_in":28800,"refresh_token_expires_in":3600}"#),
        ])
        let authentication = GitHubAuthentication(clientID: "app", client: await transport.client, store: store, now: { now })
        let started = AsyncStream<Void>.makeStream()
        let delayedResponse = AsyncStream<Void>.makeStream()
        let delayedCaller = Task {
            let token = try await authentication.accessToken()
            started.continuation.yield()
            for await _ in delayedResponse.stream { break }
            return try await authentication.accessToken(rejecting: token)
        }
        defer { delayedResponse.continuation.finish(); delayedCaller.cancel() }
        var events = started.stream.makeAsyncIterator()
        await events.next()
        let firstToken = try await authentication.accessToken()
        let recovered = try await authentication.accessToken(rejecting: firstToken)
        delayedResponse.continuation.finish()
        #expect(recovered == "fresh")
        #expect(try await delayedCaller.value == recovered)
        #expect(await transport.requests.count == 1)
        #expect(try await authentication.account() == GitHubAccount(id: 1, login: "owner"))
    }

    @Test func sharedRefreshCommitsTheRotatedCredentialsOnce() async throws {
        let now = Date()
        let reads = AsyncStream<Void>.makeStream()
        let store = MemoryGitHubCredentialStore(onRead: { reads.continuation.yield() })
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "original",
            refreshToken: "refresh", expiresAt: now.addingTimeInterval(3600), refreshExpiresAt: now.addingTimeInterval(7200)
        )))
        let transport = GitHubTestTransport([
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"fresh","refresh_token":"fresh-refresh","expires_in":28800,"refresh_token_expires_in":3600}"#),
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"newer","refresh_token":"newer-refresh","expires_in":28800,"refresh_token_expires_in":3600}"#),
        ])
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let client = GitHubClient(transport: { request in
            started.continuation.yield()
            for await _ in release.stream { break }
            return try await transport.send(request)
        })
        let authentication = GitHubAuthentication(clientID: "app", client: client, store: store, now: { now })
        let first = Task { try await authentication.accessToken(rejecting: "original") }
        defer { release.continuation.finish(); first.cancel() }
        var startedEvents = started.stream.makeAsyncIterator()
        await startedEvents.next()
        let second = Task { try await authentication.accessToken(rejecting: "original") }
        defer { second.cancel() }
        var readEvents = reads.stream.makeAsyncIterator()
        await readEvents.next()
        await readEvents.next()
        release.continuation.finish()
        #expect(try await first.value == "fresh")
        #expect(try await second.value == "fresh")
        #expect(store.writeCount == 2)
        #expect(try await authentication.accessToken(rejecting: "fresh") == "newer")
        #expect(store.writeCount == 3)
        let credentials = try JSONDecoder().decode(GitHubCredentials.self, from: #require(store.read()))
        #expect(credentials.accessToken == "newer")
        #expect(credentials.refreshToken == "newer-refresh")
        #expect(await transport.requests.count == 2)
    }

    @Test func signingOutWhileGitHubRespondsDoesNotRestoreTheSession() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let client = GitHubClient(transport: { request in
            let body: String
            if request.url?.path == "/user" {
                started.continuation.yield()
                for await _ in release.stream { break }
                body = #"{"id":1,"login":"owner"}"#
            } else {
                body = #"{"access_token":"access"}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let authentication = GitHubAuthentication(
            clientID: "app", client: client, store: MemoryGitHubCredentialStore(), sleep: { _ in }
        )
        let signingIn = Task {
            try await authentication.finish(GitHubDeviceAuthorization(
                deviceCode: "device", userCode: "USER-CODE", verificationURI: URL(string: "https://github.com/login/device")!,
                expiresAt: .distantFuture, interval: 5
            ))
        }
        defer { release.continuation.finish(); signingIn.cancel() }
        var events = started.stream.makeAsyncIterator()
        await events.next()
        try await authentication.signOut()
        release.continuation.finish()
        await #expect(throws: GitHubError.self) { try await signingIn.value }
        #expect(try await authentication.account() == nil)
    }

    @Test func cancelledRefreshStillKeepsTheRotatedCredentials() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let store = MemoryGitHubCredentialStore()
        let now = Date()
        store.write(try JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "expired",
            refreshToken: "refresh", expiresAt: now.addingTimeInterval(-1), refreshExpiresAt: now.addingTimeInterval(3600)
        )))
        let client = GitHubClient(transport: { request in
            started.continuation.yield()
            for await _ in release.stream { break }
            let body = #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":28800,"refresh_token_expires_in":3600}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let authentication = GitHubAuthentication(clientID: "app", client: client, store: store, now: { now })
        let refreshing = Task { try await authentication.accessToken() }
        defer { release.continuation.finish(); refreshing.cancel() }
        var events = started.stream.makeAsyncIterator()
        await events.next()
        refreshing.cancel()
        release.continuation.finish()
        await #expect(throws: CancellationError.self) { try await refreshing.value }
        #expect(try await authentication.accessToken() == "rotated")
        let credentials = try JSONDecoder().decode(GitHubCredentials.self, from: #require(store.read()))
        #expect(credentials.refreshToken == "rotated-refresh")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XCODERUNNER_KEYCHAIN_TESTS"] == "1"))
    func keychainRecordsAreScopedToEachInstallation() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let session = GitHubKeychainStore(hostRoot: root)
        let other = GitHubKeychainStore(hostRoot: root.appending(path: "other"))
        defer { try? session.remove(); try? other.remove() }
        try session.write(Data("session".utf8))
        #expect(try session.read() == Data("session".utf8))
        #expect(try other.read() == nil)
        try session.write(Data("rotated".utf8))
        #expect(try session.read() == Data("rotated".utf8))
        try session.remove()
        #expect(try session.read() == nil)
    }
}
