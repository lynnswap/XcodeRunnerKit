import Foundation
import Synchronization

@objc package protocol HostSettingsBridgeProtocol {
    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

package enum HostSettingsBridge {
    package static let serviceName = "dev.lynnswap.XcodeRunnerHost.Settings"

    package static func request(_ request: HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse {
        let data = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: HostSettingsBridgeProtocol.self)
        let pending = PendingBridgeReply(connection: connection)
        return try await withCheckedThrowingContinuation { continuation in
            pending.continuation.withLock { $0 = continuation }
            connection.invalidationHandler = { pending.finish(.failure(HostSettingsError("The running host settings service is unavailable."))) }
            connection.interruptionHandler = { pending.finish(.failure(HostSettingsError("The host settings connection was interrupted."))) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in pending.finish(.failure(error)) }
            guard let remote = proxy as? any HostSettingsBridgeProtocol else {
                pending.finish(.failure(HostSettingsError("The host settings service has an incompatible interface.")))
                return
            }
            remote.perform(data) { response in
                pending.finish(Result { try JSONDecoder().decode(HostSettingsBridgeResponse.self, from: response) })
            }
        }
    }
}

private final class PendingBridgeReply: @unchecked Sendable {
    let connection: NSXPCConnection
    let continuation = Mutex<CheckedContinuation<HostSettingsBridgeResponse, any Error>?>(nil)

    init(connection: NSXPCConnection) { self.connection = connection }

    func finish(_ result: Result<HostSettingsBridgeResponse, any Error>) {
        let continuation = continuation.withLock { value in
            let saved = value
            value = nil
            return saved
        }
        guard let continuation else { return }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        continuation.resume(with: result)
    }
}

package struct HostSettingsRepository: Codable, Sendable, Equatable {
    package let id: Int
    package let fullName: String
    private enum CodingKeys: String, CodingKey { case id; case fullName = "full_name" }
    package init(id: Int, fullName: String) { self.id = id; self.fullName = fullName }
}

package struct HostGitHubRepositorySettings: Codable, Sendable, Equatable {
    package let selectedRepositoryIDs: [Int]
    package let choices: [HostSettingsRepository]
    package init(selectedRepositoryIDs: [Int], choices: [HostSettingsRepository]) {
        self.selectedRepositoryIDs = selectedRepositoryIDs
        self.choices = choices
    }
}

package enum HostSettingsBridgeRequest: Codable, Sendable {
    case getRepositories
    case updateRepositories([Int])
}

package struct HostSettingsBridgeResponse: Codable, Sendable {
    package let settings: HostGitHubRepositorySettings?
    package let error: String?
    package let synchronizationError: String?
    package init(settings: HostGitHubRepositorySettings? = nil, error: String? = nil, synchronizationError: String? = nil) {
        self.settings = settings; self.error = error; self.synchronizationError = synchronizationError
    }
}
