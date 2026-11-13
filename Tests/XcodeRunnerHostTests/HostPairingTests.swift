import CryptoKit
import Foundation
import Network
import Security
import Testing
import XcodeRunnerHostSupport
import XcodeRunnerKit
@testable import XcodeRunnerHostApp

@MainActor @Suite(.timeLimit(.minutes(1)))
struct HostPairingTests {
    /// Connects to a listener directly, because the tests do not advertise with Bonjour.
    private func local(_ port: NWEndpoint.Port?) throws -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: try #require(port))
    }

    private func waitToPair(_ management: HostManagement, as role: PairingRole = .manager) async throws -> NWEndpoint {
        switch role {
        case .manager: management.allowManagement()
        case .dashboard: management.allowDashboard()
        }
        try await waitUntil { management.pairingWindow?.port != nil }
        return try local(management.pairingWindow?.port)
    }

    /// Pairs the Macs as a person does after seeing the same code on both.
    private func pair(_ macs: PairedMacs, with management: HostManagement) async throws -> PairedMac {
        let endpoint = try await waitToPair(management, as: macs.role)
        let pairing = Task { try await macs.pair(at: endpoint) }
        try await waitUntil { macs.codeConfirmation != nil && management.pairingWindow?.request?.code != nil }
        #expect(macs.codeConfirmation?.code == management.pairingWindow?.request?.code)
        macs.confirmCode()
        management.allowPairing()
        return try await pairing.value
    }

    /// A connection that sends pairing messages without the managing host's checks.
    private func pairingConnection(to endpoint: NWEndpoint) -> NetworkConnection<Coder<PairingRequest, PairingReply, NetworkJSONCoder>> {
        NetworkConnection(to: endpoint) { Coder(sending: PairingRequest.self, receiving: PairingReply.self, using: .json) { TCP() } }
    }

    private func publicKey() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }

    /// A Mac whose settings and runners answer the managing host, as in the app.
    /// The Xcode that the Macs in these tests list, in place of the ones on the Mac that runs the tests. Its folder
    /// exists wherever Xcode is installed.
    private let xcode = InstalledXcode(
        developerDirectory: URL(filePath: "/Library/Developer", directoryHint: .notDirectory), version: "27.2", build: "27B48"
    )

    private func managedMac(
        named name: String = "Managed", store: MemorySecretStore = MemorySecretStore(), at root: URL,
        github: ((HostInstallation) -> GitHubHostSettings)? = nil
    ) -> HostSettingsModel {
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        return HostSettingsModel(
            installation: installation, github: github?(installation),
            management: HostManagement(store: store, name: name, advertises: false),
            managedMacs: PairedMacs(store: MemorySecretStore(), name: name, role: .manager, browses: false),
            installedXcodes: { [xcode] in [xcode] }
        )
    }

    @Test func pairedMacsConnectUntilTheManagingHostRemovesTheMac() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let managedStore = MemorySecretStore()
        let managerStore = MemorySecretStore()
        let managed = managedMac(store: managedStore, at: root)
        let management = managed.management
        let macs = PairedMacs(store: managerStore, name: "Manager", role: .manager, browses: false)

        let mac = try await pair(macs, with: management)
        #expect(mac.name == "Managed")
        #expect(macs.codeConfirmation == nil)
        #expect(management.pairingWindow == nil)
        #expect(management.manager == HostPairing(id: mac.id, name: "Manager", key: mac.pairing.key))
        #expect(PairedMacs(store: managerStore, name: "Manager", role: .manager, browses: false).macs == [mac])
        #expect(HostManagement(store: managedStore, name: "Managed", advertises: false).manager == management.manager)

        try await waitUntil { management.managementPort != nil }
        await macs.checkStatus(of: mac.id, at: try local(management.managementPort))
        #expect(macs.status(of: mac.id) == .online)
        // A managing host registers the Mac's runners from its own sign-in, and leaves the Mac's GitHub settings alone.
        let reply = try await HostLink.send(
            .github(.signOut), to: try local(management.managementPort), key: mac.pairing.symmetricKey, identity: mac.id.uuidString
        )
        guard case .refused("Managed shares its GitHub settings only with a dashboard.") = reply else {
            Issue.record("Expected the Mac to refuse the managing host, not \(reply)")
            return
        }

        await macs.remove(mac.id)
        #expect(macs.macs.isEmpty)
        #expect(macs.message == nil)
        #expect(managerStore.read() == nil)
        try await waitUntil { management.manager == nil }
        #expect(HostManagement(store: managedStore, name: "Managed", advertises: false).manager == nil)

        await management.shutDown()
        await macs.shutDown()
    }

    @Test func theManagingHostReadsAndChangesAPairedMacsSettings() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = managedMac(at: root)
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        let mac = try await pair(macs, with: managed.management)
        await managed.configureDefaultPool()
        await managed.refreshPoolStatus()
        try await waitUntil { managed.management.managementPort != nil }
        let endpoint = try local(managed.management.managementPort)

        await macs.checkStatus(of: mac.id, at: endpoint)
        let settings = try #require(macs.settings[mac.id])
        #expect(macs.status(of: mac.id) == .online)
        #expect(settings.report?.poolStatus?.configuration.maximumConcurrentJobs == HostInstallation.defaultMaximumConcurrentJobs)
        #expect(settings.poolDraft.capacityInput == String(HostInstallation.defaultMaximumConcurrentJobs))

        settings.poolDraft.capacityInput = "0"
        await macs.applyPoolConfiguration(of: mac.id)
        #expect(settings.saveError == "Enter a positive whole number of concurrent jobs.")
        settings.poolDraft.capacityInput = "3"
        settings.poolDraft.keepsSimulatorsForever = true
        await macs.applyPoolConfiguration(of: mac.id)
        #expect(settings.saveError == nil)
        #expect(try managed.pool.configuration() == .init(maximumConcurrentJobs: 3, simulatorRetention: .forever))
        #expect(settings.report?.poolStatus?.configuration.maximumConcurrentJobs == 3)
        // The Mac's own window shows the change, as it does for any change it did not make.
        #expect(managed.poolDraft.capacityInput == "3")

        settings.storageDirectoryInput = "Storage"
        await macs.saveStorageDirectory(of: mac.id)
        #expect(settings.storageSaveError == "Enter an absolute folder path.")
        let storage = root.appending(path: "Storage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        settings.storageDirectoryInput = storage.path(percentEncoded: false)
        await macs.saveStorageDirectory(of: mac.id)
        #expect(settings.storageSaveError == nil)
        #expect(managed.savedStorageDirectory == (try managed.installation.requestedStorageDirectory()))
        #expect(settings.report?.savedStorageDirectory == managed.savedStorageDirectory)

        // The Mac lists its own Xcodes, and saves the one that its jobs use when they name none.
        #expect(settings.report?.installedXcodes == [xcode])
        #expect(settings.xcodeSelectionInput == "")
        settings.xcodeSelectionInput = xcode.developerDirectory.path(percentEncoded: false)
        await macs.saveXcodeSelection(of: mac.id)
        #expect(settings.xcodeSaveError == nil)
        #expect(try managed.installation.developerDirectory() == xcode.developerDirectory)
        #expect(settings.report?.savedXcodeIsMissing == false)
        // The Mac's own window shows the selection, and an Xcode that is no longer installed is reported.
        #expect(managed.xcodeSelectionInput == settings.xcodeSelectionInput)
        try managed.installation.saveDeveloperDirectory(URL(filePath: "/Applications/Removed.app/Contents/Developer"))
        await managed.refreshPoolStatus()
        await macs.checkStatus(of: mac.id, at: endpoint)
        #expect(settings.report?.savedXcodeIsMissing == true)
        #expect(settings.xcodeSelectionInput == "/Applications/Removed.app/Contents/Developer")

        // The saved folder waits for the Mac's next launch. A host that launchd started restarts itself when asked.
        #expect(settings.report?.storageChangeIsPending == true)
        // A host that someone started another way is restarted by them.
        #expect(settings.report?.canRestart == false)
        guard case .refused(let refusal) = await managed.answer(.restart) else {
            Issue.record("A host that launchd did not start accepted a restart.")
            return
        }
        #expect(refusal == "\(HostPane.macName) cannot restart XcodeHomeRunner by itself. Restart it on that Mac.")
        var restarts = 0
        managed.restartHost = { restarts += 1 }
        await macs.checkStatus(of: mac.id, at: endpoint)
        #expect(settings.report?.canRestart == true)
        await macs.restart(mac.id)
        #expect(settings.restartError == nil)
        try await waitUntil { restarts == 1 }
        // From the accepted request on, the Mac takes no change that the restart would lose.
        #expect(!managed.canEditStorage)

        // A Mac that stops answering keeps only when its settings were last read.
        let readAt = settings.readAt
        await managed.management.shutDown()
        await macs.checkStatus(of: mac.id, at: endpoint)
        guard case .unreachable = macs.status(of: mac.id) else {
            Issue.record("Expected the Mac to be unreachable, not \(macs.status(of: mac.id))")
            return
        }
        #expect(settings.readAt == readAt)

        await macs.shutDown()
    }

    @Test func theManagingHostRegistersAndRemovesRunnersOnAPairedMac() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let installs = Installs()
        // The managed Mac has no GitHub sign-in, so any GitHub request from it fails the test.
        let client = await GitHubTestTransport([]).client
        let managed = managedMac(at: root) { installation in
            try? GitHubHostConfiguration(repositories: [repository])
                .save(to: installation.hostRoot.appending(path: "github-host.json"))
            return GitHubHostSettings(
                installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory), client: client,
                authentication: GitHubAuthentication(clientID: "app", client: client, store: MemorySecretStore()),
                provisioner: RunnerProvisioner(
                    installation: installation, installerURL: root.appending(path: "unused-installer.sh"), client: client,
                    hostName: "Managed Mac", prepareArchive: { _ in installation.homeDirectory.appending(path: "runner.tar.gz") },
                    installRunner: { request in try await installs.install(request, in: installation, agentID: 2) }
                )
            )
        }
        managed.github.storageIsReady = true
        try await managed.pool.configure(maximumConcurrentJobs: 1)
        await managed.refreshPoolStatus()
        let newRunner = RunnerProvisioner.runnerName(hostName: "Managed Mac", repository: repository, slot: 1)
        let newRunnerFolder = managed.installation.runnersRoot.appending(path: newRunner)

        let installation = HostInstallation(homeDirectory: root.appending(path: "Manager"))
        let existing = installation.runnersRoot.appending(path: "existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data(#"{"agentId":1,"agentName":"existing","gitHubUrl":"https://github.com/owner/Project"}"#.utf8)
            .write(to: existing.appending(path: ".runner"))
        try Data().write(to: existing.appending(path: ".xcode-runner-host"))
        let store = MemorySecretStore()
        try store.write(JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "token",
            refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
        )))
        let listing: [GitHubTestTransport.Reply] = [
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#),
        ]
        func runners(_ runners: [(id: Int, name: String)]) -> GitHubTestTransport.Reply {
            let listed = runners.map { #"{"id":\#($0.id),"name":"\#($0.name)","status":"online","busy":false,"labels":[]}"# }
            return .init(path: "/repos/owner/Project/actions/runners", body: #"{"runners":[\#(listed.joined(separator: ","))]}"#)
        }
        let bothRunners = runners([(1, "existing"), (2, newRunner)])
        let transport = GitHubTestTransport(listing + [
            // Selecting the repository leaves this Mac's runner and registers one on the managed Mac.
        ] + listing + [
            runners([(1, "existing")]), runners([(1, "existing")]),
            .init(path: "/repos/actions/runner/releases/latest", body: #"{"assets":[{"name":"actions-runner-osx-arm64-2.338.0.tar.gz","browser_download_url":"https://example.invalid/runner.tar.gz","digest":"sha256:\#(String(repeating: "a", count: 64))"}]}"#),
            .init(path: "/repos/owner/Project/actions/runners/registration-token", body: #"{"token":"registration-token"}"#),
            bothRunners,
        ] + listing + [
            // Unlinking removes this Mac's runner while the managed Mac does not answer.
            bothRunners, bothRunners, .init(path: "/repos/owner/Project/actions/runners/1", body: "", status: 204),
        ] + listing + [
            // The next synchronization reads the managed Mac again and removes its runner.
            runners([(2, newRunner)]), runners([(2, newRunner)]), runners([(2, newRunner)]), runners([(2, newRunner)]),
            .init(path: "/repos/owner/Project/actions/runners/2", body: "", status: 204),
        ])
        let managerClient = await transport.client
        let pool = HostExecutionPool(directory: installation.poolDirectory)
        try await pool.configure(maximumConcurrentJobs: 1)
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        let manager = HostSettingsModel(
            installation: installation,
            github: GitHubHostSettings(
                installation: installation, pool: pool, client: managerClient,
                authentication: GitHubAuthentication(clientID: "app", client: managerClient, store: store)
            ),
            management: HostManagement(store: MemorySecretStore(), name: "Manager", advertises: false),
            managedMacs: macs
        )
        let mac = try await pair(macs, with: managed.management)
        try await waitUntil { managed.management.managementPort != nil }
        await macs.checkStatus(of: mac.id, at: try local(managed.management.managementPort))
        await manager.github.restore()
        manager.github.storageIsReady = true

        #expect(try await manager.github.updateRepositorySelection([repository.id]) == nil)
        let request = try #require(await installs.requests.first)
        #expect(await installs.requests.count == 1)
        #expect(request.registrationToken == "registration-token")
        #expect(request.runnerName == newRunner)
        let status = try #require(manager.github.runnerStatuses.first)
        #expect(status.desiredCount == 2)
        #expect(status.onlineCount == 2)
        #expect(status.errorMessage == nil)
        // The managed Mac does not register runners from its own selection while it is managed.
        #expect(try await managed.github.updateRepositorySelection([repository.id])?.contains("Manager registers this Mac's runners") == true)

        await managed.management.shutDown()
        let unlinkMessage = try await manager.github.updateRepositorySelection([])
        #expect(unlinkMessage?.contains("Managed: The Mac could not be reached") == true)
        #expect(try RunnerDirectory(url: existing).isRemoved())
        #expect(try !RunnerDirectory(url: newRunnerFolder).isRemoved())
        let record = installation.hostRoot.appending(path: "github-host.json")
        #expect(try GitHubHostConfiguration.load(from: record).unlinkedRepositories == [repository])

        // The listener keeps its last port after shutting down, so the new one is awaited.
        let stoppedPort = managed.management.managementPort
        managed.management.start()
        try await waitUntil { managed.management.managementPort.map { $0 != stoppedPort } ?? false }
        await macs.checkStatus(of: mac.id, at: try local(managed.management.managementPort))
        await manager.github.synchronize()
        #expect(manager.github.errorMessage == nil)
        #expect(try RunnerDirectory(url: newRunnerFolder).isRemoved())
        #expect(manager.github.runnerStatuses.isEmpty)
        #expect(try GitHubHostConfiguration.load(from: record).unlinkedRepositories.isEmpty)
        #expect(await transport.requests.count == 21)

        await managed.management.shutDown()
        await macs.shutDown()
    }

    @Test func dashboardsPairWithAHostThatKeepsManagingItsMacs() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hostStore = MemorySecretStore()
        let host = managedMac(store: hostStore, at: root)
        // A host that manages a Mac cannot be managed, and is shown all the same.
        let runner = HostManagement(store: MemorySecretStore(), name: "Runner", advertises: false)
        _ = try await pair(host.managedMacs, with: runner)
        #expect(!host.canAllowManagement)
        await host.configureDefaultPool()
        await host.refreshPoolStatus()

        let first = PairedMacs(store: MemorySecretStore(), name: "Dashboard", role: .dashboard, browses: false)
        let second = PairedMacs(store: MemorySecretStore(), name: "Other Dashboard", role: .dashboard, browses: false)
        let shown = try await pair(first, with: host.management)
        let alsoShown = try await pair(second, with: host.management)
        #expect(host.management.manager == nil)
        #expect(host.management.dashboards.map(\.name) == ["Dashboard", "Other Dashboard"])
        #expect(host.canAddMacs)
        #expect(HostManagement(store: hostStore, name: "Managed", advertises: false).dashboards == host.management.dashboards)

        try await waitUntil { host.management.ports[shown.id] != nil && host.management.ports[alsoShown.id] != nil }
        let otherEndpoint = try local(host.management.ports[alsoShown.id])
        await first.checkStatus(of: shown.id, at: try local(host.management.ports[shown.id]))
        await second.checkStatus(of: alsoShown.id, at: otherEndpoint)
        #expect(first.status(of: shown.id) == .online)
        #expect(second.status(of: alsoShown.id) == .online)
        #expect(second.settings[alsoShown.id]?.report?.poolStatus?.configuration.maximumConcurrentJobs == HostInstallation.defaultMaximumConcurrentJobs)

        // Pairing again replaces the dashboard's earlier pairing on the host as well.
        let shownAgain = try await pair(first, with: host.management)
        #expect(first.macs == [shownAgain])
        #expect(first.message == nil)
        #expect(host.management.dashboards.map(\.id) == [alsoShown.id, shownAgain.id])

        // Either Mac ends the pairing, and the other dashboard stays.
        try await waitUntil { host.management.ports[shownAgain.id] != nil }
        await first.checkStatus(of: shownAgain.id, at: try local(host.management.ports[shownAgain.id]))
        await first.remove(shownAgain.id)
        #expect(first.macs.isEmpty)
        #expect(first.message == nil)
        try await waitUntil { host.management.dashboards.map(\.id) == [alsoShown.id] }
        let readAt = second.settings[alsoShown.id]?.readAt
        host.management.removeDashboard(alsoShown.id)
        #expect(HostManagement(store: hostStore, name: "Managed", advertises: false).dashboards.isEmpty)
        await second.checkStatus(of: alsoShown.id, at: otherEndpoint)
        guard case .unreachable = second.status(of: alsoShown.id) else {
            Issue.record("Expected the host to be unreachable, not \(second.status(of: alsoShown.id))")
            return
        }
        #expect(second.settings[alsoShown.id]?.readAt == readAt)

        await host.management.shutDown()
        await runner.shutDown()
        await host.managedMacs.shutDown()
        await first.shutDown()
        await second.shutDown()
    }

    @Test func aHostRegistersItsRunnersAfterADashboardChangesItsJobLimit() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let installs = Installs()
        let listing: [GitHubTestTransport.Reply] = [
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#),
        ]
        let noRunners = GitHubTestTransport.Reply(path: "/repos/owner/Project/actions/runners", body: #"{"runners":[]}"#)
        // Restoring the sign-in lists the repositories, and the limit change synchronizes once.
        let transport = GitHubTestTransport(listing + listing + [
            noRunners,
            .init(path: "/repos/actions/runner/releases/latest", body: #"{"assets":[{"name":"actions-runner-osx-arm64-2.338.0.tar.gz","browser_download_url":"https://example.invalid/runner.tar.gz","digest":"sha256:\#(String(repeating: "a", count: 64))"}]}"#),
            .init(path: "/repos/owner/Project/actions/runners/registration-token", body: #"{"token":"registration-token"}"#),
            noRunners,
        ])
        let client = await transport.client
        let credentials = MemorySecretStore()
        try credentials.write(JSONEncoder().encode(GitHubCredentials(
            clientID: "app", account: GitHubAccount(id: 1, login: "owner"), accessToken: "token",
            refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
        )))
        let host = managedMac(at: root) { installation in
            try? GitHubHostConfiguration(repositories: [repository])
                .save(to: installation.hostRoot.appending(path: "github-host.json"))
            return GitHubHostSettings(
                installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory), client: client,
                authentication: GitHubAuthentication(clientID: "app", client: client, store: credentials),
                provisioner: RunnerProvisioner(
                    installation: installation, installerURL: root.appending(path: "unused-installer.sh"), client: client,
                    hostName: "Host", prepareArchive: { _ in installation.homeDirectory.appending(path: "runner.tar.gz") },
                    installRunner: { request in try await installs.install(request, in: installation, agentID: 1) }
                )
            )
        }
        try await host.pool.configure(maximumConcurrentJobs: 1)
        await host.refreshPoolStatus()
        await host.github.restore()
        host.github.storageIsReady = true

        let dashboard = PairedMacs(store: MemorySecretStore(), name: "Dashboard", role: .dashboard, browses: false)
        let shown = try await pair(dashboard, with: host.management)
        try await waitUntil { host.management.ports[shown.id] != nil }
        await dashboard.checkStatus(of: shown.id, at: try local(host.management.ports[shown.id]))
        let settings = try #require(dashboard.settings[shown.id])

        settings.poolDraft.capacityInput = "0"
        await dashboard.applyPoolConfiguration(of: shown.id)
        #expect(settings.saveError == "Enter a positive whole number of concurrent jobs.")
        settings.poolDraft.capacityInput = "2"
        #expect(await dashboard.applyPoolConfiguration(of: shown.id))
        #expect(try host.pool.configuration()?.maximumConcurrentJobs == 2)
        // The host registers the runners for its new limit, as after its own Apply. The dashboard sends no token.
        try await waitUntil { await installs.requests.count == 2 }
        try await waitUntil { !host.github.isSynchronizing }
        #expect(await installs.requests.allSatisfy { $0.registrationToken == "registration-token" })
        #expect(await transport.requests.count == 8)
        await #expect(throws: HostLinkError.refused("Managed changes its runners only for its managing Mac.")) {
            _ = try await dashboard.requestRunners(.inventory, from: shown.id)
        }

        await host.management.shutDown()
        await dashboard.shutDown()
    }

    @Test func aDashboardSignsAHostInToGitHubAndChoosesItsRepositories() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        let transport = GitHubTestTransport([
            .init(path: "/login/device/code", body: #"{"device_code":"device-secret","user_code":"USER-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"token-secret"}"#),
            .init(path: "/user", body: #"{"id":1,"login":"owner"}"#),
            .init(path: "/user/installations", body: #"{"installations":[{"id":10}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#),
        ])
        let client = await transport.client
        // The host asks GitHub for the token once the test lets its wait end, as after the person authorizes the app.
        let authorized = AsyncStream<Void>.makeStream()
        let authentication = GitHubAuthentication(clientID: "app", client: client, store: MemorySecretStore(), sleep: { _ in
            for await _ in authorized.stream { return }
        })
        var openedOnHost: [URL] = []
        let host = managedMac(at: root) { installation in
            GitHubHostSettings(
                installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory),
                app: GitHubApp(clientID: "app", slug: "host-app"), client: client, authentication: authentication,
                openURL: { openedOnHost.append($0); return true }
            )
        }
        await host.github.restore()
        var opened: [URL] = []
        let dashboard = PairedMacs(
            store: MemorySecretStore(), name: "Dashboard", role: .dashboard, browses: false, openURL: { opened.append($0); return true }
        )
        let shown = try await pair(dashboard, with: host.management)
        try await waitUntil { host.management.ports[shown.id] != nil }
        let endpoint = try local(host.management.ports[shown.id])
        await dashboard.checkStatus(of: shown.id, at: endpoint)
        let settings = try #require(dashboard.settings[shown.id])
        #expect(settings.github?.hasRestored == true)
        #expect(settings.github?.accountLogin == nil)

        // The code appears on the dashboard, and GitHub's page opens there and not on the host.
        await dashboard.signIn(to: shown.id)
        #expect(settings.github?.signInCode?.userCode == "USER-CODE")
        #expect(opened == [URL(string: "https://github.com/login/device")!])
        #expect(openedOnHost.isEmpty)
        func sent() throws -> String { String(decoding: try JSONEncoder().encode(try #require(settings.github)), as: UTF8.self) }
        #expect(try !sent().contains("device-secret"))

        // The host finishes the sign-in and keeps the token. The dashboard's next read shows the account.
        authorized.continuation.yield()
        try await waitUntil { host.github.account != nil && !host.github.isConnecting }
        await dashboard.checkStatus(of: shown.id, at: endpoint)
        #expect(settings.github?.accountLogin == "owner")
        #expect(settings.github?.selectableRepositories == [repository])
        #expect(try !sent().contains("token-secret"))
        dashboard.addRepositories(to: shown.id)
        #expect(opened.last == URL(string: "https://github.com/apps/host-app/installations/new")!)

        settings.selectedRepositoryIDs = [repository.id]
        await dashboard.applyRepositorySelection(of: shown.id)
        #expect(settings.githubError == nil)
        #expect(settings.github?.savedRepositoryIDs == [repository.id])
        let record = host.installation.hostRoot.appending(path: "github-host.json")
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [repository])
        // The host's own window shows the selection, as it does for any change it did not make.
        #expect(host.github.selectedRepositoryIDs == [repository.id])
        // The host reports what registering the runners waits for, as its own Apply does.
        try await waitUntil { !host.github.isSavingSelection }
        await dashboard.checkStatus(of: shown.id, at: endpoint)
        #expect(settings.github?.errorMessage?.contains("pending until host storage is ready") == true)

        await dashboard.signOut(of: shown.id)
        #expect(settings.github?.accountLogin == nil)
        #expect(host.github.account == nil)
        #expect(await transport.requests.count == 5)

        await host.management.shutDown()
        await dashboard.shutDown()
    }

    @Test func aDashboardReachesAHostsMacsThroughTheHost() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = managedMac(named: "Host", at: root.appending(path: "Host"))
        let runner = managedMac(named: "Runner", at: root.appending(path: "Runner"))
        var restarts = 0
        runner.restartHost = { restarts += 1 }
        await runner.configureDefaultPool()
        await runner.refreshPoolStatus()
        let managed = try await pair(host.managedMacs, with: runner.management)
        try await waitUntil { runner.management.managementPort != nil }
        await host.managedMacs.checkStatus(of: managed.id, at: try local(runner.management.managementPort))

        // The dashboard pairs with the host only, and lists the Mac that the host manages.
        let dashboard = PairedMacs(store: MemorySecretStore(), name: "Dashboard", role: .dashboard, browses: false)
        let shown = try await pair(dashboard, with: host.management)
        try await waitUntil { host.management.ports[shown.id] != nil }
        let endpoint = try local(host.management.ports[shown.id])
        await dashboard.checkStatus(of: shown.id, at: endpoint)
        let macs = dashboard.macsManaged(by: shown.id)
        #expect(macs.listedMacs == [managed.listed])
        #expect(macs.status(of: managed.id) == .online)
        #expect(runner.management.dashboards.isEmpty)

        // It changes the Mac through the host, with the checks of the Mac's own window.
        let settings = try #require(macs.settings(of: managed.id))
        #expect(settings.poolDraft.capacityInput == String(HostInstallation.defaultMaximumConcurrentJobs))
        settings.poolDraft.capacityInput = "0"
        await macs.applyPoolConfiguration(of: managed.id)
        #expect(settings.saveError == "Enter a positive whole number of concurrent jobs.")
        settings.poolDraft.capacityInput = "2"
        #expect(await macs.applyPoolConfiguration(of: managed.id))
        #expect(try runner.pool.configuration()?.maximumConcurrentJobs == 2)
        // The host's own pane for the Mac shows the change as well.
        #expect(host.managedMacs.settings[managed.id]?.report?.poolStatus?.configuration.maximumConcurrentJobs == 2)
        settings.storageDirectoryInput = "Storage"
        await macs.saveStorageDirectory(of: managed.id)
        #expect(settings.storageSaveError == "Enter an absolute folder path.")
        await macs.restart(managed.id)
        #expect(settings.restartError == nil)
        try await waitUntil { restarts == 1 }

        // The host pairs with a waiting Mac, and the person compares the code on the dashboard.
        let other = HostManagement(store: MemorySecretStore(), name: "Other", advertises: false)
        let waiting = try await waitToPair(other)
        macs.discoverPairableMacs()
        try await waitUntil { host.managedMacs.isDiscovering }
        host.managedMacs.pairableMacsChanged([.init(id: "other", name: "Other", endpoint: waiting)])
        try await waitUntil { macs.waitingMacs == [WaitingMac(id: "other", name: "Other")] }
        let adding = Task { try await macs.pair(with: "other") }
        try await waitUntil { macs.codeConfirmation != nil && other.pairingWindow?.request?.code != nil }
        #expect(macs.codeConfirmation?.code == other.pairingWindow?.request?.code)
        #expect(other.pairingWindow?.request?.requesterName == "Host")
        // Only the dashboard that started the pairing gets its code and confirms it.
        let anotherDashboard = UUID()
        let attempt = try #require(host.managedMacsRelay.report(for: shown.id).pairingAttempt)
        #expect(host.managedMacsRelay.report(for: anotherDashboard).codeConfirmation == nil)
        _ = await host.managedMacsRelay.answer(.confirmCode(attempt: attempt), from: anotherDashboard)
        #expect(host.managedMacs.codeConfirmation?.isConfirmed == false)
        macs.confirmCode()
        other.allowPairing()
        let added = try await adding.value
        #expect(added.name == "Other")
        #expect(host.managedMacs.macs.map(\.id) == [managed.id, added.id])
        #expect(other.manager?.name == "Host")
        macs.stopDiscoveringPairableMacs()

        // Removing a Mac on the dashboard ends its pairing with the host.
        try await waitUntil { other.managementPort != nil }
        await host.managedMacs.checkStatus(of: added.id, at: try local(other.managementPort))
        await macs.remove(added.id)
        #expect(macs.message == nil)
        #expect(macs.listedMacs == [managed.listed])
        #expect(host.managedMacs.macs.map(\.id) == [managed.id])
        try await waitUntil { other.manager == nil }

        // A Mac that the host cannot reach appears that way, with the time the host last read it.
        await dashboard.checkStatus(of: shown.id, at: endpoint)
        let readAt = try #require(settings.readAt)
        await runner.management.shutDown()
        let watching = Task { await macs.watchSettings(of: managed.id) }
        try await waitUntil {
            if case .unreachable = macs.status(of: managed.id) { true } else { false }
        }
        watching.cancel()
        #expect(settings.readAt == readAt)

        await host.management.shutDown()
        await host.managedMacsRelay.shutDown()
        await host.managedMacs.shutDown()
        await other.shutDown()
        await dashboard.shutDown()
    }

    @Test func macsThatRunDifferentVersionsSayWhichOneToUpdate() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let managerStore = MemorySecretStore()
        let managed = managedMac(at: root)
        let management = managed.management
        let macs = PairedMacs(store: managerStore, name: "Manager", role: .manager, browses: false)
        let mac = try await pair(macs, with: management)
        try await waitUntil { management.managementPort != nil }
        let endpoint = try local(management.managementPort)

        // The managing host is updated first. Each Mac names the other one's version, and neither reads its messages.
        let updated = PairedMacs(
            store: managerStore, name: "Manager", role: .manager, browses: false, version: HostLink.version + 1
        )
        await updated.checkStatus(of: mac.id, at: endpoint)
        #expect(updated.status(of: mac.id) == .incompatible(.older))
        #expect(management.versionMismatches == [mac.id: .newer])
        #expect(updated.settings[mac.id]?.report == nil)

        // The pairing is kept, so the Macs connect again once they run the same version.
        await macs.checkStatus(of: mac.id, at: endpoint)
        #expect(macs.status(of: mac.id) == .online)
        #expect(management.versionMismatches.isEmpty)

        // A Mac that waits to pair with another version is listed with the reason, and does not pair.
        updated.discoverPairableMacs()
        updated.pairableMacsChanged([.init(id: "waiting", name: "Waiting", endpoint: endpoint, version: HostLink.version)])
        #expect(updated.waitingMacs == [WaitingMac(id: "waiting", name: "Waiting", mismatch: .older)])
        await #expect(throws: HostLinkError.incompatible(.older)) { try await updated.pair(with: "waiting") }
        // A Mac that waits refuses a Mac of another version that asks without having listed it.
        let other = HostManagement(store: MemorySecretStore(), name: "Other", advertises: false)
        let waiting = try await waitToPair(other)
        await #expect(throws: HostLinkError.refused("Other runs an older version of XcodeHomeRunner. Update it to pair.")) {
            try await updated.pair(at: waiting)
        }
        #expect(other.manager == nil)
        await other.shutDown()

        await management.shutDown()
        await macs.shutDown()
        await updated.shutDown()
    }

    @Test func aMacRefusesAPairingRequestForAnotherRole() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let manager = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        let endpoint = try await waitToPair(management, as: .dashboard)

        await #expect(throws: HostLinkError.refused("Managed is waiting for a dashboard, not a managing Mac.")) {
            try await manager.pair(at: endpoint)
        }
        #expect(management.manager == nil)
        #expect(management.dashboards.isEmpty)
        // The person opened the Mac to dashboards, so it keeps waiting for one.
        #expect(management.pairingWindow?.role == .dashboard)
        #expect(management.pairingWindow?.request == nil)

        await management.shutDown()
    }

    @Test func removalReportsAMacThatCouldNotForgetThePairing() async throws {
        let managedStore = MemorySecretStore()
        let management = HostManagement(store: managedStore, name: "Managed", advertises: false)
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        let mac = try await pair(macs, with: management)
        try await waitUntil { management.managementPort != nil }
        await macs.checkStatus(of: mac.id, at: try local(management.managementPort))
        managedStore.failWrites(with: CocoaError(.fileWriteNoPermission))

        await macs.remove(mac.id)
        #expect(macs.macs.isEmpty)
        #expect(macs.message?.contains("Managed could not remove the pairing") == true)
        #expect(management.manager?.id == mac.id)

        await management.shutDown()
        await macs.shutDown()
    }

    @Test func refusingAPairingRequestStopsWaitingToPair() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        let endpoint = try await waitToPair(management)
        let pairing = Task { try await macs.pair(at: endpoint) }
        try await waitUntil { management.pairingWindow?.request?.code != nil }

        management.refusePairing()
        await #expect(throws: HostLinkError.refused("Managed did not allow the pairing.")) { try await pairing.value }
        #expect(management.pairingWindow == nil)
        #expect(management.pairingMessage == "You did not allow Manager to manage this Mac.")
        #expect(management.manager == nil)
        #expect(macs.macs.isEmpty)

        await management.shutDown()
    }

    @Test func aManagingHostThatLeavesAfterConfirmingStopsPairing() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        let endpoint = try await waitToPair(management)
        let pairing = Task { try await macs.pair(at: endpoint) }
        try await waitUntil { macs.codeConfirmation != nil && management.pairingWindow?.request?.code != nil }
        macs.confirmCode()
        // Lets the confirmation arrive before the managing host leaves.
        try await Task.sleep(for: .milliseconds(200))

        pairing.cancel()
        try await waitUntil { management.pairingWindow == nil }
        #expect(management.pairingMessage == "Pairing stopped because Manager did not finish pairing.")
        management.allowPairing()
        #expect(management.manager == nil)

        await management.shutDown()
    }

    @Test func aKeyThatDoesNotMatchItsCommitmentIsRefusedAndStopsPairing() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let connection = pairingConnection(to: try await waitToPair(management))

        try await connection.send(PairingRequest.begin(
            commitment: Data(SHA256.hash(data: publicKey())), pairingID: UUID(), requesterName: "Someone", role: .manager, version: HostLink.version
        ))
        _ = try await connection.receive()
        try await connection.send(PairingRequest.reveal(publicKey: publicKey()))
        guard case .refused(let message) = try await connection.receive().content else {
            Issue.record("The Mac did not refuse the key.")
            return
        }
        #expect(message == "Managed could not verify the pairing request.")
        try await waitUntil { management.pairingWindow == nil }
        #expect(management.pairingMessage == "Pairing stopped because Someone did not finish pairing.")

        await management.shutDown()
    }

    @Test func aMacTakesOnePairingRequestAtATime() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        let endpoint = try await waitToPair(management)
        let first = pairingConnection(to: endpoint)
        try await first.send(PairingRequest.begin(
            commitment: Data(SHA256.hash(data: publicKey())), pairingID: UUID(), requesterName: "First", role: .manager, version: HostLink.version
        ))
        _ = try await first.receive()

        await #expect(throws: HostLinkError.refused("Managed is confirming another pairing.")) { try await macs.pair(at: endpoint) }
        #expect(management.pairingWindow?.request?.requesterName == "First")

        await management.shutDown()
    }

    @Test func theManagingHostPairsOnlyAfterThePersonConfirmsTheCode() async throws {
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        // Someone who answers in place of the Mac can prove the key it agreed, and says it paired right away.
        let impostor = try NetworkListener {
            Coder(sending: PairingReply.self, receiving: PairingRequest.self, using: .json) { TCP() }
        }
        let ports = AsyncStream<NWEndpoint.Port>.makeStream()
        let answered = AsyncStream<Void>.makeStream()
        impostor.onStateUpdate { listener, state in
            if case .ready = state, let port = listener.port { ports.continuation.yield(port) }
        }
        let serving = Task {
            try await impostor.run { connection in
                guard case .begin(let commitment, let pairingID, let requesterName, let role, _) = try await connection.receive().content else { return }
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let publicKey = privateKey.publicKey.rawRepresentation
                let hostID = UUID()
                try await connection.send(PairingReply.publicKey(publicKey, name: "Impostor", hostID: hostID))
                guard case .reveal(let requesterKey) = try await connection.receive().content else { return }
                let agreement = try PairingAgreement(
                    privateKey: privateKey, peerPublicKey: requesterKey,
                    transcript: PairingAgreement.transcript(
                        commitment: commitment, requesterKey: requesterKey, macKey: publicKey, pairingID: pairingID,
                        requesterName: requesterName, role: role, macName: "Impostor", hostID: hostID
                    )
                )
                try await connection.send(PairingReply.paired(agreement.proof(from: .mac)))
                answered.continuation.yield()
                _ = try await connection.receive()
            }
        }
        var readyPorts = ports.stream.makeAsyncIterator()
        let endpoint = try local(await readyPorts.next())
        let pairing = Task { try await macs.pair(at: endpoint) }
        var answers = answered.stream.makeAsyncIterator()
        await answers.next()
        try await waitUntil { macs.codeConfirmation != nil }

        try await Task.sleep(for: .milliseconds(200))
        #expect(macs.macs.isEmpty)
        #expect(macs.codeConfirmation?.isConfirmed == false)

        pairing.cancel()
        _ = await pairing.result
        serving.cancel()
    }

    @Test func pairingTheSameMacAgainReplacesItsEarlierPairing() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)

        _ = try await pair(macs, with: management)
        management.stopManagement()
        let second = try await pair(macs, with: management)
        #expect(macs.macs == [second])
        #expect(management.manager?.id == second.id)

        await management.shutDown()
        await macs.shutDown()
    }

    @Test func managementConnectionsUseAnEphemeralKeyExchange() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = PairedMacs(store: MemorySecretStore(), name: "Manager", role: .manager, browses: false)
        let mac = try await pair(macs, with: management)
        try await waitUntil { management.managementPort != nil }
        let connection = NetworkConnection(
            to: try local(management.managementPort),
            using: HostLink.clientParameters(key: mac.pairing.symmetricKey, identity: mac.id.uuidString)
        )
        try await connection.send(Versioned(HostLinkRequest.settings(.read), version: HostLink.version))
        _ = try await connection.receive()

        // Without ECDHE, anyone who records the connections can read them once the pairing key leaks.
        let metadata = try #require(connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)
        let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata)
        #expect(suite.rawValue == UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))

        await management.shutDown()
        await macs.shutDown()
    }
}

/// Installs that a managed Mac ran, each leaving a hosted runner as the installer does.
private actor Installs {
    private(set) var requests: [RunnerProvisioner.InstallationRequest] = []

    func install(_ request: RunnerProvisioner.InstallationRequest, in installation: HostInstallation, agentID: Int) throws {
        requests.append(request)
        let directory = installation.runnersRoot.appending(path: request.runnerName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registration = #"{"agentId":\#(agentID),"agentName":"\#(request.runnerName)","gitHubUrl":"https://github.com/\#(request.repository.fullName)"}"#
        try Data(registration.utf8).write(to: directory.appending(path: ".runner"))
        try Data().write(to: directory.appending(path: ".xcode-runner-host"))
    }
}
