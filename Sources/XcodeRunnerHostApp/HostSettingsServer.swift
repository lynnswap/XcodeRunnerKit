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
            // What this Mac does once the command has its answer, as after a dashboard's request.
            var followUp: FollowUp?
            do {
                switch try request.get() {
                case .link(let data):
                    let answer = await answer(try JSONDecoder().decode(HostLinkRequest.self, from: data))
                    followUp = answer.followUp
                    response = HostSettingsBridgeResponse(reply: try JSONEncoder().encode(answer.reply))
                case .pairing(let data):
                    let report = try settings.answer(try JSONDecoder().decode(HostPairingRequest.self, from: data))
                    response = HostSettingsBridgeResponse(reply: try JSONEncoder().encode(report))
                case .updateRunnerLabels(let labels):
                    (response, followUp) = await change(.saveRunnerLabels(labels))
                case .setPaused(let isPaused):
                    (response, followUp) = await change(.setPaused(isPaused))
                case let request:
                    response = await handle(request)
                }
            } catch {
                response = HostSettingsBridgeResponse(error: error.localizedDescription)
            }
            do { reply(try JSONEncoder().encode(response)) }
            catch { reply(Data(#"{"error":"Could not encode the host settings response."}"#.utf8)) }
            guard let followUp else { return }
            // The command has the answer before this Mac registers runners or restarts, as a dashboard has: a host
            // that stops right away would otherwise end the connection with the reply still unsent.
            if let connection {
                // The connection calls the block on its own queue.
                await withCheckedContinuation { sent in connection.scheduleSendBarrierBlock { @Sendable in sent.resume() } }
            }
            await followUp()
        }
    }

    /// Names the commands on this Mac where a host tells its dashboards apart, as for the pairing that one starts.
    private static let commands = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    /// Changes a setting for `xcode-runner host settings`, which reads the saved value afterwards.
    private func change(_ request: HostSettingsRequest) async -> (HostSettingsBridgeResponse, FollowUp?) {
        let answer = await answer(.settings(request))
        if case .refused(let reason) = answer.reply { return (HostSettingsBridgeResponse(error: reason), nil) }
        return (HostSettingsBridgeResponse(), answer.followUp)
    }

    /// What this Mac does after an answer was sent.
    private typealias FollowUp = @MainActor () async -> Void

    /// Answers a command's request as this Mac answers a dashboard's, with what follows the answer.
    private func answer(_ request: HostLinkRequest) async -> (reply: HostLinkReply, followUp: FollowUp?) {
        let settings = settings
        switch request {
        case .settings(let request):
            let reply = await settings.answer(request)
            let followUp: FollowUp = { await settings.finish(request, answeredWith: reply, registersRunners: true) }
            return (reply, followUp)
        case .packageAccess(let change):
            return (await github.changePackageAccess(change), nil)
        case .github(let request):
            let reply = await github.answer(request)
            // The selection is saved, and its runners are registered and removed after the answer.
            guard request.updatesRunnerRegistrations, case .github = reply else { return (reply, nil) }
            let followUp: FollowUp = { await settings.github.synchronizeSavedSelection() }
            return (reply, followUp)
        case .macs(let request):
            let answer = await settings.managedMacsRelay.answer(request, from: Self.commands)
            // The limit is saved, and runners are registered for it after the answer.
            guard answer.registrationsChanged else { return (answer.reply, nil) }
            let followUp: FollowUp = { await settings.github.synchronize() }
            return (answer.reply, followUp)
        default:
            return (.refused("\(HostPane.macName) takes no such command."), nil)
        }
    }

    func handle(_ request: HostSettingsBridgeRequest) async -> HostSettingsBridgeResponse {
        switch request {
        case .link, .pairing, .updateRunnerLabels, .setPaused:
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
