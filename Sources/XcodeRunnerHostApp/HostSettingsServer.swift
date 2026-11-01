import Darwin
import Foundation
import XcodeRunnerHostSupport

/// Connects local automation to the running app's repository settings owner.
@MainActor
final class HostSettingsServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    nonisolated private let handler: HostSettingsRequestHandler

    init(github: GitHubHostSettings, listener: NSXPCListener = NSXPCListener(machServiceName: HostSettingsBridge.serviceName)) {
        self.listener = listener
        self.handler = HostSettingsRequestHandler(github: github)
        super.init()
        listener.delegate = self
    }

    func start() { listener.activate() }
    func stop() { listener.invalidate() }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: HostSettingsBridgeProtocol.self)
        connection.exportedObject = handler
        connection.activate()
        return true
    }
}

@MainActor
final class HostSettingsRequestHandler: NSObject, HostSettingsBridgeProtocol {
    private let github: GitHubHostSettings

    init(github: GitHubHostSettings) { self.github = github }

    nonisolated func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        Task { @MainActor in
            let response: HostSettingsBridgeResponse
            do {
                response = await handle(try JSONDecoder().decode(HostSettingsBridgeRequest.self, from: request))
            } catch {
                response = HostSettingsBridgeResponse(error: error.localizedDescription)
            }
            do { reply(try JSONEncoder().encode(response)) }
            catch { reply(Data(#"{"error":"Could not encode the host settings response."}"#.utf8)) }
        }
    }

    func handle(_ request: HostSettingsBridgeRequest) async -> HostSettingsBridgeResponse {
        switch request {
        case .getRepositories:
            return HostSettingsBridgeResponse(settings: github.repositorySettings)
        case .updateRepositories(let repositoryIDs):
            do {
                let synchronizationError = try await github.updateRepositorySelection(Set(repositoryIDs))
                return HostSettingsBridgeResponse(settings: github.repositorySettings, synchronizationError: synchronizationError)
            } catch {
                return HostSettingsBridgeResponse(settings: github.repositorySettings, error: error.localizedDescription)
            }
        }
    }
}
