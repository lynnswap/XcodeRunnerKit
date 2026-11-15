import Darwin
import Foundation
import XcodeRunnerHostSupport

/// Connects commands on this Mac to the running host's settings.
@MainActor
final class HostSettingsServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    nonisolated private let handler: HostSettingsRequestHandler

    init(settings: HostSettingsModel, listener: NSXPCListener = NSXPCListener(machServiceName: HostSettingsBridge.serviceName)) {
        self.listener = listener
        self.handler = HostSettingsRequestHandler(settings: settings)
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
    private let settings: HostSettingsModel
    private var github: GitHubHostSettings { settings.github }

    init(settings: HostSettingsModel) { self.settings = settings }

    nonisolated func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        // The connection that delivers the reply, which this method has only while it is called.
        nonisolated(unsafe) let connection = NSXPCConnection.current()
        Task { @MainActor in
            let request = Result { try JSONDecoder().decode(HostSettingsBridgeRequest.self, from: request) }
            let response: HostSettingsBridgeResponse
            var answered: (request: HostLinkRequest, reply: HostLinkReply)?
            do {
                switch try request.get() {
                case .link(let data):
                    let request = try JSONDecoder().decode(HostLinkRequest.self, from: data)
                    let answer = await answer(request)
                    answered = (request, answer)
                    response = HostSettingsBridgeResponse(reply: try JSONEncoder().encode(answer))
                case let request:
                    response = await handle(request)
                }
            } catch {
                response = HostSettingsBridgeResponse(error: error.localizedDescription)
            }
            do { reply(try JSONEncoder().encode(response)) }
            catch { reply(Data(#"{"error":"Could not encode the host settings response."}"#.utf8)) }
            guard let answered else { return }
            // The command has the answer before this Mac registers runners or restarts, as a dashboard has: a host
            // that stops right away would otherwise end the connection with the reply still unsent.
            if let connection {
                // The connection calls the block on its own queue.
                await withCheckedContinuation { sent in connection.scheduleSendBarrierBlock { @Sendable in sent.resume() } }
            }
            switch answered.request {
            case .settings(let request):
                await settings.finish(request, answeredWith: answered.reply, registersRunners: true)
            case .github(.applySelection):
                // The selection is saved, and its runners are registered and removed after the answer, as for a dashboard.
                if case .github = answered.reply { await github.synchronizeDashboardSelection() }
            default:
                break
            }
        }
    }

    /// Answers a command's request as this Mac answers a dashboard's.
    private func answer(_ request: HostLinkRequest) async -> HostLinkReply {
        switch request {
        case .settings(let request): await settings.answer(request)
        case .github(let request): await github.answer(request)
        default: .refused("\(HostPane.macName) takes no such command.")
        }
    }

    func handle(_ request: HostSettingsBridgeRequest) async -> HostSettingsBridgeResponse {
        switch request {
        case .link:
            return HostSettingsBridgeResponse(error: "A request for the host is answered with its reply.")
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
