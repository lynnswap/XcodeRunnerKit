import Foundation
import Testing
import XcodeRunnerHostSupport
import XcodeRunnerKit
@testable import XcodeRunnerHost

@MainActor @Suite(.timeLimit(.minutes(1)))
struct HostSettingsBridgeTests {
    @Test func repositoryRequestsUseSavedSelectionAndPreserveTheGUIDraft() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let record = installation.hostRoot.appending(path: "github-host.json")
        let first = GitHubRepository(id: 1, fullName: "owner/First")
        let second = GitHubRepository(id: 2, fullName: "owner/Second")
        try GitHubHostConfiguration(repositories: [first, second]).save(to: record)
        let github = GitHubHostSettings(installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory))
        github.selectedRepositoryIDs = []
        let listener = NSXPCListener.anonymous()
        let server = HostSettingsServer(github: github, listener: listener)
        server.start()
        defer { server.stop() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HostSettingsBridgeProtocol.self)
        connection.activate()
        defer { connection.invalidate() }

        let before = try await request(.getRepositories, over: connection)
        #expect(before.settings?.selectedRepositoryIDs == [1, 2])
        #expect(before.settings?.choices.map(\.fullName) == ["owner/First", "owner/Second"])
        let updated = try await request(.updateRepositories([1]), over: connection)
        #expect(updated.error == nil)
        #expect(updated.settings?.selectedRepositoryIDs == [1])
        #expect(updated.synchronizationError?.contains("pending") == true)
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [first])
        #expect(github.selectedRepositoryIDs.isEmpty)

        let invalid = try await request(.updateRepositories([1, 999]), over: connection)
        #expect(invalid.error != nil)
        #expect(invalid.settings?.selectedRepositoryIDs == [1])
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [first])
    }

    private func request(_ request: HostSettingsBridgeRequest, over connection: NSXPCConnection) async throws -> HostSettingsBridgeResponse {
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let remote = proxy as? any HostSettingsBridgeProtocol else {
                continuation.resume(throwing: CocoaError(.coderInvalidValue))
                return
            }
            remote.perform(data) { response in
                continuation.resume(with: Result { try JSONDecoder().decode(HostSettingsBridgeResponse.self, from: response) })
            }
        }
    }
}
