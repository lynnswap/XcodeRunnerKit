import Foundation
import Testing
import XcodeRunnerHostSupport
import XcodeRunnerKit
@testable import XcodeRunnerHostApp

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
        let (server, connection) = serve(host(installation, github: github))
        defer {
            connection.invalidate()
            server.stop()
        }

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

    @Test func commandsReadAndChangeTheHostAsADashboardDoes() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let settings = host(installation)
        let (server, connection) = serve(settings)
        defer {
            connection.invalidate()
            server.stop()
        }
        func perform(_ request: HostLinkRequest) async throws -> HostSettingsReport {
            let reply = try await HostControl.reply(to: request) { try await self.request($0, over: connection) }
            guard case .settings(let report) = reply else { throw CocoaError(.coderInvalidValue) }
            return report
        }

        #expect(try await perform(.settings(.setPaused(true))).isPaused)
        #expect(installation.isPaused())
        #expect(try await perform(.settings(.saveRunnerLabels(["fast", "gpu"]))).runnerLabels == ["fast", "gpu"])
        #expect(try installation.runnerLabels() == ["fast", "gpu"])
        let status = try await perform(.settings(.read))
        #expect(status.isPaused && status.runnerLabels == ["fast", "gpu"])

        // The host's reason for refusing is the command's failure. This host was not started by launchd.
        await #expect(throws: HostSettingsError.self) { _ = try await perform(.settings(.restart)) }
        // A request that the host takes only from a paired Mac is refused as well.
        await #expect(throws: HostSettingsError.self) { _ = try await perform(.unpair) }

        // `xcode-runner host settings` changes the labels and the pause through the host as well, and gets its refusal.
        #expect(try await request(.setPaused(false), over: connection).error == nil)
        #expect(!installation.isPaused())
        #expect(try await request(.updateRunnerLabels(["one,two"]), over: connection).error != nil)
        #expect(try installation.runnerLabels() == ["fast", "gpu"])

        // The host's pairings and its reasons for refusing reach a command the same way.
        #expect(try await HostControl.pairing(.read) { try await self.request($0, over: connection) }.dashboards.isEmpty)
        await #expect(throws: HostSettingsError.self) {
            _ = try await HostControl.pairing(.refuse) { try await self.request($0, over: connection) }
        }
    }

    @Test func commandsConnectTheHostToGitHub() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        let transport = GitHubTestTransport([
            .init(path: "/login/device/code", body: #"{"device_code":"device-secret","user_code":"USER-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"token-secret"}"#),
            .init(path: "/user", body: #"{"id":1,"login":"owner"}"#),
            .init(path: "/user/installations", body: #"{"installations":[]}"#),
        ])
        let client = await transport.client
        // The host asks GitHub for the token once the test lets its wait end, as after the code is entered.
        let authorized = AsyncStream<Void>.makeStream()
        let authentication = GitHubAuthentication(clientID: "app", client: client, store: MemorySecretStore(), sleep: { _ in
            for await _ in authorized.stream { return }
        })
        var opened: [URL] = []
        let github = GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
            app: GitHubApp(clientID: "app", slug: "host-app"), client: client, authentication: authentication,
            openURL: { opened.append($0); return true }
        )
        let (server, connection) = serve(host(installation, github: github))
        defer {
            connection.invalidate()
            server.stop()
        }
        func perform(_ request: GitHubRequest) async throws -> GitHubReport {
            let reply = try await HostControl.reply(to: .github(request)) { try await self.request($0, over: connection) }
            guard case .github(let report) = reply else { throw CocoaError(.coderInvalidValue) }
            return report
        }

        // The command gets the code to enter, and the host opens no browser for a sign-in that a command started.
        #expect(try await perform(.signIn).isConnecting)
        try await waitUntil { github.deviceAuthorization != nil }
        let waiting = try await perform(.read)
        #expect(waiting.signInCode?.userCode == "USER-CODE")
        #expect(waiting.accountLogin == nil)
        #expect(opened.isEmpty)

        authorized.continuation.yield()
        try await waitUntil { github.account != nil && !github.isConnecting }
        #expect(try await perform(.read).accountLogin == "owner")
        #expect(try await perform(.signOut).accountLogin == nil)

        // Reloading without a sign-in fails on the host, which says so in its answer for the command to fail with.
        #expect(try await perform(.reloadRepositories).errorMessage != nil)
    }

    @Test func commandsReachAMacThatTheHostManages() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = self.host(HostInstallation(homeDirectory: root.appending(path: "Host")))
        let managed = self.host(HostInstallation(homeDirectory: root.appending(path: "Managed")), named: "Managed")
        // The host pairs with the Mac as a person does after seeing the same code on both.
        managed.management.allowManagement()
        try await waitUntil { managed.management.pairingWindow?.port != nil }
        let pairing = Task {
            try await host.managedMacs.pair(at: .hostPort(host: "127.0.0.1", port: try #require(managed.management.pairingWindow?.port)))
        }
        try await waitUntil { host.managedMacs.codeConfirmation != nil && managed.management.pairingWindow?.request?.code != nil }
        host.managedMacs.confirmCode()
        managed.management.allowPairing()
        let mac = try await pairing.value
        try await waitUntil { managed.management.managementPort != nil }
        await host.managedMacs.checkStatus(
            of: mac.id, at: .hostPort(host: "127.0.0.1", port: try #require(managed.management.managementPort))
        )
        let (server, connection) = serve(host)
        defer {
            connection.invalidate()
            server.stop()
        }
        let bridge: (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = {
            try await self.request($0, over: connection)
        }

        // The command names the Mac as the host lists it, and the host passes the change on as for a dashboard.
        let paused = try await HostControl.managed("Managed", on: nil, over: bridge) { .setPaused(true, mac: $0) }
        #expect(paused.id == mac.id && paused.settings?.isPaused == true)
        #expect(managed.installation.isPaused())
        await #expect(throws: HostSettingsError.self) {
            _ = try await HostControl.managed("Another Mac", on: nil, over: bridge) { .read(refreshing: $0) }
        }

        await managed.management.shutDown()
        await host.managedMacs.shutDown()
    }

    @Test func aCommandPairsTheHostWithAMacToManageGivenItsCode() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = self.host(HostInstallation(homeDirectory: root.appending(path: "Host")))
        let managed = self.host(HostInstallation(homeDirectory: root.appending(path: "Managed")), named: "Managed")
        let (server, connection) = serve(host)
        defer {
            connection.invalidate()
            server.stop()
        }
        let bridge: (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = {
            try await self.request($0, over: connection)
        }
        /// Lists the Mac as found on the network once the host looks for Macs, while it waits for a managing host.
        func find() async throws {
            _ = try managed.answer(.allow(.manager))
            try await waitUntil { managed.management.pairingWindow?.port != nil && host.managedMacs.isDiscovering }
            host.managedMacs.pairableMacsChanged([.init(
                id: UUID().uuidString, name: "Managed",
                endpoint: .hostPort(host: "127.0.0.1", port: try #require(managed.management.pairingWindow?.port))
            )])
        }

        // Another code than the host's ends the pairing on the host.
        var shown: [String] = []
        let refused = Task {
            try await HostControl.pairManagedMac(named: "Managed", on: nil, timeout: .seconds(30), over: bridge) {
                shown.append($0.code)
            } otherCode: { shown.last == "000000" ? "111111" : "000000" }
        }
        try await find()
        await #expect(throws: HostSettingsError.self) { _ = try await refused.value }
        #expect(host.managedMacs.macs.isEmpty)
        try await waitUntil { !host.managedMacs.isPairing }
        _ = try managed.answer(.cancel)
        // The Mac no longer advertises the wait that ended.
        host.managedMacs.pairableMacsChanged([])

        // Each Mac's command gets the other's code, as an agent that runs both passes them on.
        let pairing = Task {
            try await HostControl.pairManagedMac(named: "Managed", on: nil, timeout: .seconds(30), over: bridge) {
                shown.append($0.code)
            } otherCode: {
                try await waitUntil { managed.management.pairingWindow?.request?.code != nil }
                let macCode = try #require(managed.management.pairingWindow?.request?.code)
                _ = try managed.answer(.confirm(code: try #require(shown.last)))
                return macCode
            }
        }
        try await find()
        let report = try await pairing.value
        #expect(report.pairedMac?.name == "Managed" && report.macs.map(\.name) == ["Managed"])
        #expect(managed.management.manager?.name == "Host")

        await managed.management.shutDown()
        await host.managedMacs.shutDown()
    }

    private func host(_ installation: HostInstallation, github: GitHubHostSettings? = nil, named name: String = "Host") -> HostSettingsModel {
        HostSettingsModel(
            installation: installation, github: github,
            management: HostManagement(store: MemorySecretStore(), name: name, advertises: false),
            managedMacs: PairedMacs(store: MemorySecretStore(), name: name, role: .manager, browses: false)
        )
    }

    /// Starts the settings service of a host, and connects to it as a command does.
    private func serve(_ settings: HostSettingsModel) -> (server: HostSettingsServer, connection: NSXPCConnection) {
        let listener = NSXPCListener.anonymous()
        let server = HostSettingsServer(settings: settings, listener: listener)
        server.start()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HostSettingsBridgeProtocol.self)
        connection.activate()
        return (server, connection)
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
