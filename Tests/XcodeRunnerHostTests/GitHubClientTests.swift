import Foundation
import Testing
@testable import XcodeRunnerHost

actor GitHubTestTransport {
    struct Reply: Sendable {
        let path: String
        let body: String
        var status = 200
        var headers: [String: String] = [:]
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = try #require(replies.first, "Unexpected HTTP request: \(request.url?.absoluteString ?? "nil")")
        replies.removeFirst()
        #expect(request.url?.path == reply.path)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers
        ))
        return (Data(reply.body.utf8), response)
    }

    var client: GitHubClient { GitHubClient(transport: { try await self.send($0) }) }
}

struct GitHubClientTests {
    @Test func repositoryLookupUsesTheRegistrationNameAndReturnsTheStableIdentifier() async throws {
        let transport = GitHubTestTransport([
            .init(path: "/repos/example/Previous", body: #"{"id":1,"full_name":"example/Renamed"}"#),
        ])
        let client = await transport.client
        let repository = try await client.repository(fullName: "example/Previous", accessToken: "user-token")
        #expect(repository.id == 1)
        #expect(repository.fullName == "example/Renamed")
    }

    @Test func repositoriesFollowEveryInstallationPageAndDeduplicate() async throws {
        let transport = GitHubTestTransport([
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#,
                  headers: ["Link": #"<https://api.github.com/user/installations?page=2>; rel="next""#]),
            .init(path: "/user/installations", body: #"{"installations":[{"id":20}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Zebra"}]}"#,
                  headers: ["Link": #"<https://api.github.com/user/installations/10/repositories?page=2>; rel="next""#]),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":2,"full_name":"owner/Apple"}]}"#),
            .init(path: "/user/installations/20/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Zebra"}]}"#),
        ])
        let client = await transport.client
        let repositories = try await client.listRepositories(accessToken: "user-token")
        #expect(repositories.map(\.fullName) == ["owner/Apple", "owner/Zebra"])
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer user-token" })
        #expect(requests.allSatisfy { $0.url?.host == "api.github.com" })
        #expect(URLComponents(url: try #require(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems?.contains(
            URLQueryItem(name: "page", value: "2")
        ) == true)
    }

    @Test func runnerRegistrationUsesTheRepositoryEndpoint() async throws {
        let transport = GitHubTestTransport([
            .init(path: "/repos/owner/repository/actions/runners", body: #"{"runners":[{"id":3,"name":"runner-1","status":"online","busy":true,"labels":[{"name":"xcode-runner"}]}]}"#),
            .init(path: "/repos/owner/repository/actions/runners/registration-token", body: #"{"token":"registration"}"#),
        ])
        let client = await transport.client
        let repository = GitHubRepository(id: 1, fullName: "owner/repository")
        let runners = try await client.listRunners(repository: repository, accessToken: "user")
        #expect(runners.first?.busy == true)
        #expect(runners.first?.labels.map(\.name) == ["xcode-runner"])
        #expect(try await client.registrationToken(repository: repository, accessToken: "user") == "registration")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
    }

    @Test func runnerArchiveComesFromTheOfficialReleaseWithItsDigest() async throws {
        let checksum = String(repeating: "a", count: 64)
        let transport = GitHubTestTransport([
            .init(path: "/repos/actions/runner/releases/latest", body: """
                {"assets":[{"name":"actions-runner-osx-arm64-2.0.0.tar.gz",
                "browser_download_url":"https://github.com/actions/runner/releases/download/v2.0.0/runner.tar.gz",
                "digest":"sha256:\(checksum)"}]}
                """),
            .init(path: "/repos/actions/runner/releases/latest", body: #"{"assets":[{"name":"actions-runner-osx-arm64-2.0.0.tar.gz","browser_download_url":"https://github.com/runner.tar.gz","digest":null}]}"#),
        ])
        let client = await transport.client
        let download = try await client.runnerDownload(accessToken: "user")
        #expect(download.sha256Checksum == checksum)
        #expect(download.filename == "actions-runner-osx-arm64-2.0.0.tar.gz")
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        await #expect(throws: GitHubError.self) { try await client.runnerDownload(accessToken: "user") }
    }

    @Test func permissionFailuresKeepGitHubsExplanation() async throws {
        let transport = GitHubTestTransport([
            .init(path: "/repos/owner/repository/actions/runners/registration-token",
                  body: #"{"message":"Resource not accessible by integration"}"#, status: 403),
        ])
        let client = await transport.client
        do {
            _ = try await client.registrationToken(repository: GitHubRepository(id: 1, fullName: "owner/repository"), accessToken: "user")
            Issue.record("Registration unexpectedly succeeded.")
        } catch let GitHubError.response(status, message) {
            #expect(status == 403)
            #expect(message == "Resource not accessible by integration")
        }
    }
}
