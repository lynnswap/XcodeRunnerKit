import CryptoKit
import Foundation
import Network
import Observation
import Security
import Synchronization
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

    /// A Mac that answers requests with `handle`, in place of a paired Mac's settings.
    private func listener(
        key: SymmetricKey, identity: String = "listener",
        handle: @escaping @Sendable (
            HostLinkRequest, _ reply: @escaping @Sendable (HostLinkReply) async throws -> Void,
            _ next: @escaping @Sendable () async throws -> HostLinkRequest
        ) async throws -> Void
    ) async throws -> (task: Task<Void, any Error>, endpoint: NWEndpoint) {
        let (ports, port) = AsyncStream<NWEndpoint.Port>.makeStream()
        let task = Task {
            try await HostLink.listen(
                key: key, identity: identity, advertising: nil, ready: { port.yield($0) }, connected: { _ in }, handle: handle
            )
        }
        var found = ports.makeAsyncIterator()
        return (task, try local(await found.next()))
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
        github: ((HostInstallation) -> GitHubHostSettings)? = nil, operationTool: URL = URL(filePath: "/usr/bin/false")
    ) -> HostSettingsModel {
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        return HostSettingsModel(
            installation: installation, github: github?(installation),
            management: HostManagement(store: store, name: name, advertises: false),
            managedMacs: PairedMacs(store: MemorySecretStore(), name: name, role: .manager, browses: false),
            installedXcodes: { [xcode] in [xcode] }, operationTool: operationTool
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

        // A Mac that listens for the pairing under another key no longer has this one.
        await #expect(throws: HostLinkError.rejected) {
            try await HostLink.send(
                .settings(.read), to: try local(management.managementPort), key: SymmetricKey(size: .bits256),
                identity: mac.id.uuidString
            )
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

    @Test func aMacChangesEndpointsWhileReceivingJobDefaults() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = managedMac(at: root.appending(path: "Manager"))
        let worker = managedMac(at: root.appending(path: "Worker"))
        let macs = manager.managedMacs
        let mac = try await pair(macs, with: worker.management)
        try manager.saveJobOptions([.environment: [.init(name: "LANG", value: "en")]])

        @Sendable @MainActor func answer(_ request: HostLinkRequest) async throws -> HostLinkReply {
            if case .syncJobOptions(let options) = request { try worker.applyJobOptions(options, from: mac.id) }
            return await worker.answer(.read)
        }

        let requested = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let old = try await listener(key: mac.pairing.symmetricKey, identity: mac.id.uuidString) { request, reply, _ in
            if case .syncJobOptions = request {
                requested.continuation.yield(())
                for await _ in release.stream {}
            }
            try await reply(try await answer(request))
        }
        let replacement = try await listener(key: mac.pairing.symmetricKey, identity: mac.id.uuidString) { request, reply, _ in
            let snapshot = try await answer(request)
            // This first read matches the latest defaults, but predates the write accepted at the old endpoint.
            release.continuation.finish()
            try await reply(snapshot)
        }
        let first = Task { await macs.checkStatus(of: mac.id, at: old.endpoint) }
        var arrivals = requested.stream.makeAsyncIterator()
        _ = await arrivals.next()
        try manager.saveJobOptions([.environment: []])
        await macs.checkStatus(of: mac.id, at: replacement.endpoint)
        release.continuation.finish()
        await first.value

        #expect(macs.status(of: mac.id) == .online)
        #expect(worker.jobOptions?.environment == [])
        #expect(macs.settingsSyncErrors.isEmpty)
        old.task.cancel()
        replacement.task.cancel()
        await worker.management.shutDown()
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

        // Leaving the pane as its shared read starts must still deliver the answer to the other observers.
        let read = Task { await macs.checkStatus(of: mac.id, at: endpoint) }
        withObservationTracking { _ = macs.status(of: mac.id) } onChange: { read.cancel() }
        await read.value
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

        // The Mac saves the build service that its jobs use when they name none, and reports one that is not there.
        settings.buildServiceInput = "BuildService"
        await macs.saveBuildService(of: mac.id)
        #expect(settings.buildServiceSaveError == "Enter an absolute path to a build service's executable.")
        let buildService = root.appending(path: "BuildService")
        settings.buildServiceInput = buildService.path(percentEncoded: false)
        await macs.saveBuildService(of: mac.id)
        #expect(settings.buildServiceSaveError == nil)
        #expect(try managed.installation.buildServiceExecutableURL() == buildService)
        #expect(settings.report?.savedBuildServiceIsMissing == true)
        #expect(managed.buildServiceInput == settings.buildServiceInput)
        settings.buildServiceInput = ""
        await macs.saveBuildService(of: mac.id)
        #expect(try managed.installation.buildServiceExecutableURL() == nil)
        #expect(settings.report?.savedBuildServiceIsMissing == false)

        // The Mac keeps the labels of its runners, and its managing host reads them with its runner folders and
        // records those that it put on the runners.
        settings.runnerLabelsInput = "Fast, xcode-27"
        #expect(await macs.saveRunnerLabels(of: mac.id))
        #expect(try managed.installation.runnerLabels() == ["fast", "xcode-27"])
        #expect(settings.runnerLabelsInput == "fast, xcode-27")
        #expect(managed.runnerLabelsInput == "fast, xcode-27")
        settings.runnerLabelsInput = "fast, self-hosted"
        #expect(await !macs.saveRunnerLabels(of: mac.id))
        #expect(settings.runnerLabelsError == "Every runner already has the label self-hosted.")
        let runnerMac = PairedRunnerMac(id: mac.id, macs: macs)
        #expect(try await runnerMac.runners().labels == ["fast", "xcode-27"])
        try await runnerMac.markLabelsApplied(["fast"])
        #expect(try managed.installation.appliedRunnerLabels() == ["fast"])

        // A paused Mac keeps that state across launches, and its own window shows it.
        #expect(settings.report?.isPaused == false)
        await macs.setPaused(true, of: mac.id)
        #expect(settings.pauseError == nil)
        #expect(settings.report?.isPaused == true)
        #expect(managed.isPaused)
        #expect(managedMac(at: root).isPaused)
        await macs.setPaused(false, of: mac.id)
        #expect(settings.report?.isPaused == false)
        #expect(!managedMac(at: root).isPaused)

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

    @Test func managedRunnerFetchesOnlyPackagesGrantedByItsHost() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = managedMac(named: "Host", at: root)
        let runner = managedMac(at: root.appending(path: "Runner"))
        runner.github.enablePackageAccess(on: runner.installation)
        let mac = try await pair(host.managedMacs, with: runner.management)
        try await waitUntil { runner.management.managementPort != nil }
        await host.managedMacs.checkStatus(of: mac.id, at: try local(runner.management.managementPort))
        let name = "owner/Library"
        guard case .packageRepositories([name]) = await host.github.changePackageAccess(.add(name)) else {
            Issue.record("The manager could not save the package grant.")
            return
        }
        #expect(runner.github.packageRouting == .applied([name]))
        #expect(try runner.github.packageRepositories().isEmpty)

        // Hold the last bytes until the runner has received the start of the Git response.
        let result = root.appending(path: "response")
        let relay = Process()
        relay.executableURL = URL(filePath: "/usr/bin/python3")
        relay.arguments = ["-I", "-c", """
            from http.server import BaseHTTPRequestHandler, HTTPServer
            import os, sys, time
            class Git(BaseHTTPRequestHandler):
                def log_message(self, *args): pass
                def do_POST(self):
                    body = self.rfile.read(int(self.headers['Content-Length']))
                    valid = (self.path == '/owner/Library.git/git-upload-pack' and
                             self.headers['Authorization'] == 'Bearer test' and self.headers['Git-Protocol'] == 'version=2')
                    self.send_response(200 if valid else 403)
                    self.send_header('Content-Type', 'application/x-git-upload-pack-result')
                    self.end_headers()
                    self.wfile.write(body[:65536])
                    self.wfile.flush()
                    deadline = time.monotonic() + 10
                    while os.stat(sys.argv[1]).st_size < 65536:
                        if time.monotonic() > deadline: return
                        time.sleep(.02)
                    self.wfile.write(body[65536:])
            server = HTTPServer(('127.0.0.1', 0), Git)
            print(server.server_port, flush=True)
            server.timeout = 30
            server.handle_request()
            """, result.path(percentEncoded: false)]
        let portPipe = Pipe()
        relay.standardOutput = portPipe
        try relay.run()
        defer { if relay.isRunning { relay.terminate() } }
        portPipe.fileHandleForWriting.closeFile()
        let portText = String(decoding: portPipe.fileHandleForReading.availableData, as: UTF8.self)
        let port = try #require(UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let config = host.installation.packageGitConfiguration.deletingPathExtension().appendingPathExtension("json")
        try JSONSerialization.data(withJSONObject: ["port": Int(port), "authorization": "Bearer test"]).write(to: config)

        let (server, endpoint) = try await listener(key: mac.pairing.symmetricKey, identity: mac.id.uuidString) {
            request, reply, next in
            try await host.managedMacs.answerPackageRequest(request, from: mac.pairing, reply: reply, next: next)
        }
        defer { server.cancel() }
        let body = Data((0..<(96 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let source = root.appending(path: "request")
        try body.write(to: source)
        try Data().write(to: result)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: result)
        defer { try? input.close(); try? output.close() }
        let fetch = PackageFetch(repository: name, operation: .uploadPack, protocolV2: true, gzip: false)
        try await fetch.transfer(to: endpoint, manager: mac.pairing, input: input, output: output)
        let received = try Data(contentsOf: result)
        let newline = try #require(received.firstIndex(of: 10))
        let headers = try JSONDecoder().decode(PackageFetch.Response.self, from: received[..<newline])
        #expect(headers.status == 200)
        #expect(received.suffix(from: newline + 1) == body)

        // A failed reload stops the relay. The manager must see that the runner needs its routes again.
        try Data("invalid".utf8).write(to: runner.installation.hostRoot.appending(path: "managed-package-repositories.json"))
        await runner.github.preparePackageAccess()
        guard case .failed = runner.github.packageRouting else {
            Issue.record("An unreadable routing file must be reported to the manager.")
            return
        }

        guard case .packageRepositories([]) = await host.github.changePackageAccess(.remove(name)) else {
            Issue.record("The manager could not remove the package grant.")
            return
        }
        await runner.github.preparePackageAccess()
        #expect(runner.github.packageRouting == .applied([]))
        let denied = await #expect(throws: HostSettingsError.self) {
            try await fetch.transfer(to: endpoint, manager: mac.pairing, input: input, output: output)
        }
        #expect(denied?.message.contains("not allowed") == true)
        await runner.github.shutDown()
        await runner.management.shutDown()
        await host.managedMacs.shutDown()
    }

    @Test func damagedJobDefaultsDoNotPreventEndingManagement() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = managedMac(named: "Host", at: root.appending(path: "Host"))
        let runner = managedMac(named: "Runner", at: root.appending(path: "Runner"))
        _ = try await pair(host.managedMacs, with: runner.management)
        var options = HostJobOptions()
        options.environment = [.init(name: "GROUP", value: "managed")]
        try runner.applyJobOptions(options, from: #require(runner.management.manager?.id))
        let file = runner.installation.hostRoot.appending(path: "JobDefaults/options.json")
        try Data("damaged".utf8).write(to: file)
        runner.management.stopManagement()
        #expect(runner.management.manager == nil)
        #expect(runner.jobOptionsReadError != nil)
        await runner.management.shutDown()
        await host.managedMacs.shutDown()
    }

    @Test func theManagingHostRegistersAndRemovesRunnersOnAPairedMac() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitHubRepository(id: 1, fullName: "owner/Project", isPrivate: false)
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
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project","private":false}]}"#),
        ]
        func runners(_ runners: [(id: Int, name: String)]) -> GitHubTestTransport.Reply {
            let listed = runners.map { #"{"id":\#($0.id),"name":"\#($0.name)","status":"online","busy":false,"labels":[]}"# }
            return .init(path: "/repos/owner/Project/actions/runners", body: #"{"runners":[\#(listed.joined(separator: ","))]}"#)
        }
        let bothRunners = runners([(1, "existing"), (2, newRunner)])
        let transport = GitHubTestTransport(listing + [
            // Selecting the repository leaves this Mac's runner and registers one on the managed Mac.
        ] + listing + [
            runners([(1, "existing")]),
            .init(path: "/repos/owner/Project/actions/permissions/fork-pr-contributor-approval", body: #"{"approval_policy":"all_external_contributors"}"#),
            runners([(1, "existing")]),
            .init(path: "/repos/owner/Project/actions/permissions/fork-pr-contributor-approval", body: #"{"approval_policy":"all_external_contributors"}"#),
            .init(path: "/repos/actions/runner/releases/latest", body: #"{"assets":[{"name":"actions-runner-osx-arm64-2.338.0.tar.gz","browser_download_url":"https://example.invalid/runner.tar.gz","digest":"sha256:\#(String(repeating: "a", count: 64))"}]}"#),
            .init(path: "/repos/owner/Project/actions/permissions/fork-pr-contributor-approval", body: #"{"approval_policy":"all_external_contributors"}"#),
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
        #expect(await transport.requests.count == 24)

        await managed.management.shutDown()
        await macs.shutDown()
    }

    @Test func theAddMacSheetSetsUpThisMacAndAllowsThePairingThatShowsTheHostsCode() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The host that the installer starts on this Mac, which answers once it is installed.
        let thisMac = managedMac(at: root)
        var isInstalled = false
        let setup = ThisMacSetup(install: { isInstalled = true }, pairing: { request in
            guard isInstalled else { throw HostSettingsError("This Mac has no host.") }
            return try thisMac.answer(request)
        }, hasHost: { isInstalled })
        let host = PairedMacs(store: MemorySecretStore(), name: "Host", role: .manager, browses: false)

        setup.start()
        try await waitUntil { setup.phase == .waiting }
        #expect(thisMac.management.pairingWindow?.role == .manager)
        try await waitUntil { thisMac.management.pairingWindow?.port != nil }

        let pairing = Task { try await host.pair(at: try local(thisMac.management.pairingWindow?.port)) }
        try await waitUntil { host.codeConfirmation != nil }
        let code = try #require(host.codeConfirmation?.code)
        // Another code than the host's is one that another Mac showed, and this Mac's host refuses it.
        await #expect(throws: HostSettingsError.self) { try await setup.allowPairing(showing: code == "000000" ? "111111" : "000000") }
        await #expect(throws: (any Error).self) { _ = try await pairing.value }
        #expect(thisMac.management.manager == nil)

        setup.start()
        try await waitUntil { setup.phase == .waiting && thisMac.management.pairingWindow?.port != nil }
        let secondPairing = Task { try await host.pair(at: try local(thisMac.management.pairingWindow?.port)) }
        try await waitUntil { host.codeConfirmation != nil }
        try await setup.allowPairing(showing: try #require(host.codeConfirmation?.code))
        host.confirmCode()
        _ = try await secondPairing.value
        #expect(thisMac.management.manager?.name == "Host")

        await thisMac.management.shutDown()
        await host.shutDown()
    }

    @Test func commandsPairAHostWithADashboardGivenItsCode() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = managedMac(at: root)
        let dashboard = PairedMacs(store: MemorySecretStore(), name: "Dashboard", role: .dashboard, browses: false)

        // A command confirms nothing before a Mac asks, and takes one wait at a time.
        #expect(throws: HostSettingsError.self) { try host.answer(.confirm(code: "000000")) }
        #expect(try host.answer(.allow(.dashboard)).window?.role == .dashboard)
        #expect(throws: HostSettingsError.self) { try host.answer(.allow(.dashboard)) }
        try await waitUntil { host.management.pairingWindow?.port != nil }
        let endpoint = try local(host.management.pairingWindow?.port)

        // Another code than the one that this Mac shows for the request refuses it and ends the wait.
        let refused = Task { try await dashboard.pair(at: endpoint) }
        try await waitUntil { dashboard.codeConfirmation != nil && host.management.pairingWindow?.request?.code != nil }
        let shown = try #require(try host.answer(.read).window?.code)
        #expect(throws: HostSettingsError.self) { try host.answer(.confirm(code: shown == "000000" ? "111111" : "000000")) }
        #expect(host.management.pairingWindow == nil)
        await #expect(throws: (any Error).self) { try await refused.value }
        let afterRefusal: HostPairingReport = try host.answer(.read)
        #expect(afterRefusal.dashboards.isEmpty && afterRefusal.ended?.paired == nil)

        // The code that the dashboard shows pairs the Macs once the dashboard confirmed too.
        _ = try host.answer(.allow(.dashboard))
        try await waitUntil { host.management.pairingWindow?.port != nil }
        let pairing = Task { try await dashboard.pair(at: try self.local(host.management.pairingWindow?.port)) }
        try await waitUntil { dashboard.codeConfirmation != nil && host.management.pairingWindow?.request?.code != nil }
        let code = try #require(dashboard.codeConfirmation?.code)
        let confirmed = try host.answer(.confirm(code: code)).window
        #expect(confirmed?.isAllowed == true)
        dashboard.confirmCode()
        let paired = try await pairing.value
        try await waitUntil { host.management.pairingWindow == nil }
        let report: HostPairingReport = try host.answer(.read)
        #expect(report.dashboards.map(\.name) == ["Dashboard"] && report.dashboards.map(\.id) == [paired.id])
        // A command that confirmed the wait learns from its end that this Mac paired.
        #expect(report.ended == .init(id: try #require(confirmed?.id), paired: paired.id))
        // The report is what a command prints, and it has no key.
        #expect(try !String(decoding: JSONEncoder().encode(report), as: UTF8.self).contains("key"))

        #expect(try host.answer(.removeDashboard(paired.id)).dashboards.isEmpty)
        #expect(throws: HostSettingsError.self) { try host.answer(.removeDashboard(paired.id)) }
        await host.management.shutDown()
        await dashboard.shutDown()
    }

    @Test func aDashboardsCommandPairsWithAHostGivenItsCode() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = managedMac(at: root)
        let store = MemorySecretStore()
        let dashboard = PairedMacs(store: store, name: "Dashboard", role: .dashboard, browses: false)
        // The dashboard that is open while the command runs, with the pairings that it read when it started.
        let open = PairedMacs(store: store, name: "Dashboard", role: .dashboard, browses: false)
        dashboard.discoverPairableMacs()
        /// Lists the host as found on the network while it waits for a dashboard.
        func find() async throws -> PairedMacs.PairableMac {
            _ = try host.answer(.allow(.dashboard))
            try await waitUntil { host.management.pairingWindow?.port != nil }
            let found = PairedMacs.PairableMac(id: UUID().uuidString, name: "Managed", endpoint: try local(host.management.pairingWindow?.port))
            dashboard.pairableMacsChanged([found])
            return found
        }

        // Another code than this Mac's ends the pairing here, and the host stops waiting for its confirmation.
        var shown: [String] = []
        await #expect(throws: HostLinkError.self) {
            _ = try await dashboard.pair(with: try await find().id) { shown.append($0.code) } otherCode: {
                shown.last == "000000" ? "111111" : "000000"
            }
        }
        #expect(shown.count == 1 && dashboard.macs.isEmpty)
        try await waitUntil { host.management.pairingWindow?.request == nil }
        _ = try host.answer(.cancel)

        // Each Mac's command gets the other's code, as an agent that runs both passes them on.
        let paired = try await dashboard.pair(with: try await find().id) { shown.append($0.code) } otherCode: {
            try await waitUntil { host.management.pairingWindow?.request?.code != nil }
            let hostCode = try #require(host.management.pairingWindow?.request?.code)
            _ = try host.answer(.confirm(code: try #require(shown.last)))
            return hostCode
        }
        #expect(dashboard.macs.map(\.listed) == [paired])
        #expect(DashboardPairingReport(dashboard).hosts.map(\.name) == ["Managed"])
        // The open dashboard reads the host that the command saved, so it does not save its earlier list over it.
        #expect(open.macs.isEmpty)
        open.reload()
        #expect(open.macs.map(\.listed) == [paired])
        try await waitUntil { host.management.dashboards.map(\.id) == [paired.id] }

        dashboard.stopDiscoveringPairableMacs()
        await host.management.shutDown()
        await dashboard.shutDown()
        await open.shutDown()
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
        // The menu bar item's menu names the host with its state and jobs.
        let menuBar = Dashboard(hosts: second)
        menuBar.menuNeedsUpdate(menuBar.statusMenu)
        #expect(menuBar.statusMenu.items.first?.title == "Managed")
        #expect(menuBar.statusMenu.items.first?.subtitle == "Starting · 0 running · 0 waiting · Limit 4")

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
        menuBar.menuNeedsUpdate(menuBar.statusMenu)
        #expect(menuBar.statusMenu.items.first?.subtitle == "Not responding")

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
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project","private":false}]}"#),
        ]
        let noRunners = GitHubTestTransport.Reply(path: "/repos/owner/Project/actions/runners", body: #"{"runners":[]}"#)
        // Restoring the sign-in lists the repositories, and the limit change synchronizes once.
        let transport = GitHubTestTransport(listing + listing + [
            noRunners,
            .init(path: "/repos/owner/Project/actions/permissions/fork-pr-contributor-approval", body: #"{"approval_policy":"all_external_contributors"}"#),
            .init(path: "/repos/actions/runner/releases/latest", body: #"{"assets":[{"name":"actions-runner-osx-arm64-2.338.0.tar.gz","browser_download_url":"https://example.invalid/runner.tar.gz","digest":"sha256:\#(String(repeating: "a", count: 64))"}]}"#),
            .init(path: "/repos/owner/Project/actions/permissions/fork-pr-contributor-approval", body: #"{"approval_policy":"all_external_contributors"}"#),
            .init(path: "/repos/owner/Project/actions/runners/registration-token", body: #"{"token":"registration-token"}"#),
            .init(path: "/repos/owner/Project/actions/permissions/fork-pr-contributor-approval", body: #"{"approval_policy":"all_external_contributors"}"#),
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
        #expect(await transport.requests.count == 11)
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
        let organizationRepository = GitHubRepository(id: 2, fullName: "team/Shared")
        let transport = GitHubTestTransport([
            .init(path: "/login/device/code", body: #"{"device_code":"device-secret","user_code":"USER-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            .init(path: "/login/oauth/access_token", body: #"{"access_token":"token-secret"}"#),
            .init(path: "/user", body: #"{"id":1,"login":"owner"}"#),
            .init(path: "/user/installations", body: #"{"installations":[{"id":10,"account":{"id":1},"html_url":"https://github.com/settings/installations/10"}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#),
            .init(path: "/user/installations", body: #"{"installations":[{"id":10},{"id":20}]}"#),
            .init(path: "/user/installations/10/repositories", body: #"{"repositories":[{"id":1,"full_name":"owner/Project"}]}"#),
            .init(path: "/user/installations/20/repositories", body: #"{"repositories":[{"id":2,"full_name":"team/Shared"}]}"#),
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
        // The app's only installation is for the account that signed in, so the page that opens is that installation's.
        dashboard.addRepositories(to: shown.id)
        #expect(opened.last == URL(string: "https://github.com/settings/installations/10")!)
        #expect(settings.github?.addOrganizationURL == URL(string: "https://github.com/apps/host-app/installations/new"))
        await dashboard.reloadRepositories(of: shown.id)
        #expect(settings.github?.selectableRepositories == [repository, organizationRepository])
        let overview = OverviewModel(hosts: dashboard, host: shown, addMac: {})
        overview.selection = [organizationRepository.id]
        overview.save()
        let reopened = OverviewModel(hosts: dashboard, host: shown, addMac: {})
        #expect(reopened.isSaving)
        try await waitUntil { !reopened.isSaving }
        // The reply acknowledges the write before the dashboard has read the result of runner registration.
        #expect(settings.github?.isSavingSelection == true)
        #expect(settings.githubError == nil)
        #expect(settings.github?.savedRepositoryIDs == [organizationRepository.id])
        let record = host.installation.hostRoot.appending(path: "github-host.json")
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [organizationRepository])
        // The host's own window shows the selection, as it does for any change it did not make.
        #expect(host.github.selectedRepositoryIDs == [organizationRepository.id])
        // The host reports what registering the runners waits for, as its own Apply does.
        try await waitUntil { !host.github.isSavingSelection }
        await dashboard.checkStatus(of: shown.id, at: endpoint)
        #expect(settings.github?.errorMessage?.contains("pending until host storage is ready") == true)

        // Another dashboard edits the host before this one retries registration alongside a build option.
        let latest: Set<Int> = [repository.id, organizationRepository.id]
        try host.github.saveSelection(latest)
        let option = HostJobOptions.Entry(name: "LANG", value: "en_US.UTF-8")
        reopened[jobOptions: .environment] = [option]
        reopened.save()
        try await waitUntil { !reopened.isSaving }
        #expect(host.github.savedRepositoryIDs == latest)
        #expect(reopened.selection == latest)
        try await waitUntil { !host.github.isSavingSelection }
        #expect(host.jobOptions?.environment == [option])

        await dashboard.signOut(of: shown.id, confirmedLogin: "previous-account")
        #expect(settings.github?.accountLogin == "owner")
        #expect(settings.github?.errorMessage?.contains("account changed") == true)
        await dashboard.signOut(of: shown.id, confirmedLogin: "owner")
        #expect(settings.github?.accountLogin == nil)
        #expect(host.github.account == nil)
        #expect(await transport.requests.count == 8)

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
        runner.sampleResources()
        runner.sampleResources()
        var ownDefaults = HostJobOptions()
        ownDefaults.environment = [.init(name: "RUN_GROUP", value: "local")]
        try runner.saveJobOptions([.environment: ownDefaults.environment])
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

        let overview = OverviewModel(hosts: dashboard, host: shown, addMac: {})
        let batchMode = HostJobOptions.Entry(name: "SWIFT_ENABLE_BATCH_MODE", value: "NO")
        let enabled = HostJobOptions.Entry(name: "TEST_RUNNER_LANGUAGE", value: "ja")
        let disabled = HostJobOptions.Entry(name: "EXTRA", value: "off", isEnabled: false)
        overview[jobOptions: .buildSettings] = [batchMode]
        overview[jobOptions: .environment] = [enabled, disabled]
        overview.save()
        try await waitUntil { !overview.isSaving }
        #expect(overview.jobOptionsError == nil)
        #expect(host.jobOptions?.environment == [enabled, disabled])
        #expect(runner.jobOptions?.environment == [enabled])
        #expect(try runner.installation.jobOptionsRecord().options(managedBy: runner.management.manager?.id).buildSettings == [batchMode])
        overview[jobOptions: .environment] = []
        overview.revert()
        #expect(overview[jobOptions: .environment] == [enabled, disabled])

        // The settings report carries only the latest sample. Opening Activity also retrieves the runner's history.
        let pane = MacPaneModel(macs: macs, id: managed.id, relay: (dashboard, shown.id), removed: {})
        let activity = Task { await pane.watchActivity() }
        defer { activity.cancel() }
        try await waitUntil { pane.resourceHistory.samples == runner.resourceHistory.samples }
        let clock = try #require(runner.resourceHistory.samples.last?.clock)
        runner.sampleResources()
        runner.sampleResources()
        #expect(try await macs.readActivity(of: managed.id, after: clock) == Array(runner.resourceHistory.samples.suffix(2)))
        try await waitUntil { pane.resourceHistory.samples == runner.resourceHistory.samples }
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
        await macs.setPaused(true, of: managed.id)
        #expect(settings.pauseError == nil)
        #expect(runner.isPaused)
        #expect(settings.report?.isPaused == true)
        guard case .macs(let inventory) = try await HostLink.send(.macs(.listRunners), to: endpoint,
            key: shown.pairing.symmetricKey, identity: shown.id.uuidString) else {
            Issue.record("The host did not return its runner Macs.")
            return
        }
        #expect(inventory.runnerMacs?.map(\.name) == [shown.name, managed.name])
        #expect(inventory.runnerMacs?.last?.slots == RunnerSlots(state: "paused", limit: 2))
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
        // While the host can only return its cached settings, the graph uses the reported samples.
        try await waitUntil { pane.resourceHistory.samples == settings.resourceHistory.samples }
        activity.cancel()
        let watching = Task { await macs.watchSettings(of: managed.id) }
        try await waitUntil {
            if case .unreachable = macs.status(of: managed.id) { true } else { false }
        }
        watching.cancel()
        #expect(settings.readAt == readAt)

        // The runner keeps the last defaults offline and receives edits before taking another forwarded build.
        var changed = try #require(host.jobOptions)
        changed.environment = []
        overview[jobOptions: .environment] = []
        overview.save()
        try await waitUntil { !overview.isSaving }
        #expect(!overview.hasEdits)
        #expect(host.jobOptions == changed)
        #expect(try runner.installation.jobOptionsRecord().options(managedBy: runner.management.manager?.id).environment == [enabled])
        runner.management.start()
        try await waitUntil { runner.management.managementPort != nil }
        await host.managedMacs.checkStatus(of: managed.id, at: try local(runner.management.managementPort))
        #expect(try runner.installation.jobOptionsRecord().options(managedBy: runner.management.manager?.id) == changed.enabledEntries)
        runner.management.stopManagement()
        #expect(try runner.installation.jobOptionsRecord().options(managedBy: runner.management.manager?.id) == ownDefaults)
        await runner.management.shutDown()

        await host.management.shutDown()
        await host.managedMacsRelay.shutDown()
        await host.managedMacs.shutDown()
        await other.shutDown()
        await dashboard.shutDown()
    }

    /// Stands in for `xcode-runner` on a host: prints how the host ran it and leaves a log and a result bundle. `test`
    /// runs until the host stops it.
    private func operationTool(at root: URL) throws -> URL {
        let tool = root.appending(path: "xcode-runner")
        try Data(#"""
        #!/bin/bash
        output=${2#--output-directory=}
        mkdir -p "$output/Job/Results.xcresult"
        echo "the log of $PWD" > "$output/Job/xcodebuild.log"
        echo "the results" > "$output/Job/Results.xcresult/Info.plist"
        if [ -f "bundle-with-alias" ]; then
            ln -s Info.plist "$output/Job/Results.xcresult/InfoAlias"
        fi
        echo "arguments: $*"
        echo "directory: $PWD"
        echo "folder: $(basename "$(dirname "$PWD")")"
        echo "files: $(find .. \( -type f -o -type l \) | sort | tr '\n' ' ')"
        if [ -L ../link ]; then echo "link: $(readlink ../link)"; fi
        if [ -f ../changed ]; then echo "contents: $(cat ../changed)"; fi
        if [ "$1" = test ]; then
            trap 'kill "$!" 2>/dev/null; wait; touch "$XCODE_RUNNER_HOST_ROOT/stopped"; exit 143' TERM
            echo started
            sleep 600 &
            wait $!
        fi
        echo "Log: $output/Job/xcodebuild.log"
        exit 3
        """#.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        return tool
    }

    private func git(_ arguments: String..., in directory: URL) throws {
        let git = Process()
        git.executableURL = URL(filePath: "/usr/bin/git")
        git.arguments = ["-C", directory.path(percentEncoded: false), "-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
        git.standardOutput = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        #expect(git.terminationStatus == 0)
    }

    /// A host that a dashboard paired with, and a checkout on the dashboard with a file for each state that Git
    /// knows.
    private func hostAndCheckout(
        at root: URL
    ) async throws -> (host: HostSettingsModel, storage: HostInstallation.Storage, shown: PairedMac, endpoint: NWEndpoint, checkout: URL) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = managedMac(at: root, operationTool: try operationTool(at: root))
        let storage = try HostInstallation(homeDirectory: root.appending(path: "Home")).initializeStorage()
        host.storageDidBecomeAvailable(storage)
        let dashboard = PairedMacs(store: MemorySecretStore(), name: "Dashboard", role: .dashboard, browses: false)
        let shown = try await pair(dashboard, with: host.management)
        try await waitUntil { host.management.ports[shown.id] != nil }

        let checkout = root.appending(path: "Project")
        try FileManager.default.createDirectory(at: checkout.appending(path: "App"), withIntermediateDirectories: true)
        try git("init", "--quiet", in: checkout)
        for name in ["App/committed", "App/changed", "App/deleted", ".gitignore"] {
            try Data((name == ".gitignore" ? "ignored\n" : "committed\n").utf8).write(to: checkout.appending(path: name))
        }
        try FileManager.default.createSymbolicLink(atPath: checkout.appending(path: "App/link").path(percentEncoded: false), withDestinationPath: "committed")
        try git("add", ".", in: checkout)
        try git("commit", "--quiet", "--message", "Files", in: checkout)
        try Data("changed\n".utf8).write(to: checkout.appending(path: "App/changed"))
        try FileManager.default.removeItem(at: checkout.appending(path: "App/deleted"))
        try Data().write(to: checkout.appending(path: "App/untracked"))
        try Data().write(to: checkout.appending(path: "App/ignored"))
        // Git lists no folder without files, and a command can run in one.
        try FileManager.default.createDirectory(at: checkout.appending(path: "App/Empty"), withIntermediateDirectories: true)
        return (host, storage, shown, try local(host.management.ports[shown.id]), checkout)
    }

    /// The folders that operations leave on a host.
    private func remoteFolders(in storage: HostInstallation.Storage) -> [String] {
        [storage.workDirectory, storage.buildDirectory].flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.appending(path: "Remote").path(percentEncoded: false))) ?? []
        }
    }

    @Test func aRepeatedRunSendsSourceButLeavesDownloadedResultsOnTheDashboard() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let output = root.appending(path: "XcodeRunnerOutput")
        let job = output.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git("init", "--quiet", in: root)
        for name in ["workflow.log", "tracked.txt"] { try Data().write(to: job.appending(path: name)) }
        try git("add", "*.txt", in: root)
        try Data().write(to: root.appending(path: "new.swift"))
        let checkout = try await Checkout.containing(root)
        let files = try await checkout.files(excludingResultsIn: output)
        #expect(Set(files) == ["new.swift", "XcodeRunnerOutput/" + job.lastPathComponent + "/tracked.txt"])
    }

    @Test func compactWorkflowOutputKeepsTheFailedStepInALargeMatrix() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let successes = (1...20).map { WorkflowSummary.Job(name: "Build \($0)", status: "success") }
        let failure = WorkflowSummary.Job(name: "Test", status: "failure", step: "Run tests", logLine: 50)
        let full = WorkflowSummary(status: "failed", runner: "Runner", jobs: successes + [failure])
        try JSONEncoder().encode(full).write(to: folder.appending(path: "summary.json"))
        let json = try WorkflowSummary.report(in: folder, format: .json, exitCode: 1)
        let report = try JSONDecoder().decode(WorkflowSummary.self, from: json)
        #expect(report.jobCount == 21)
        #expect(report.jobs.count == 12)
        #expect(report.jobs.first?.step == "Run tests")
        #expect(report.jobs.first?.logLine == 50)
    }

    @Test func workflowUsesTheDashboardRefAndRepositoryFromASubdirectory() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "Sources")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git("init", "--quiet", "-b", "feature", in: root)
        try git("commit", "--quiet", "--allow-empty", "-m", "Initial", in: root)
        try git("remote", "add", "origin", "git@github.com:owner/project.git", in: root)
        let workflows = root.appending(path: ".github/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        let shared = "jobs: {test: {runs-on: fast, steps: []}}"
        try Data(shared.utf8).write(to: workflows.appending(path: "shared.yml"))
        try Data().write(to: workflows.appending(path: "unrelated.yml"))
        let caller = #"""
        env:
          RELEASE_DATE: 2026-11-21
          PATH_SUFFIX: :/opt/bin
          LIMIT: !!float .inf
        jobs: {test: {uses: "\x2e/.github/workflows/shared.yml"}}
        """#
        try Data(caller.utf8).write(to: root.appending(path: "ci.yml"))
        let checkout = try await Checkout.containing(directory)
        let workflow = try await checkout.workflow(file: "../ci.yml", event: "push")
        #expect(workflow.file == "ci.yml")
        #expect(workflow.repository == "owner/project")
        #expect(workflow.ref == "refs/heads/feature")
        #expect(workflow.localWorkflows == ["shared.yml": shared])
        try Data("shared.yml\n".utf8).write(to: root.appending(path: ".gitignore"))
        await #expect(throws: RemoteOperationFailure.self) {
            try await checkout.workflow(file: "../ci.yml", event: "push")
        }
    }

    @Test func aDashboardRunsABuildOfItsCheckoutOnAHost() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, storage, shown, endpoint, directory) = try await hostAndCheckout(at: root)
        host.hostState = .running
        try await host.pool.configure(maximumConcurrentJobs: 3)
        await host.refreshPoolStatus()
        guard case .macs(let inventory) = try await HostLink.send(.macs(.listRunners), to: endpoint,
            key: shown.pairing.symmetricKey, identity: shown.id.uuidString) else {
            Issue.record("The host did not return its runner Macs.")
            return
        }
        #expect(inventory.macs.isEmpty)
        #expect(inventory.runnerMacs == [RunnerMacStatus(name: shown.name, slots: RunnerSlots(state: "available", available: 3, limit: 3))])
        let checkout = try await Checkout.containing(directory.appending(path: "App/Empty"))
        #expect(checkout.directory == "App/Empty")
        #expect(checkout.name == "Project")
        let outputDirectory = root.appending(path: "Output")

        let received = Output()
        let status = try await RemoteOperationClient.run(
            "build", arguments: ["--scheme=App", "--", "-quiet"], in: checkout, on: shown, at: endpoint,
            outputDirectory: outputDirectory
        ) { received.append($0) }
        let lines = received.text.split(separator: "\n").map(String.init)

        #expect(status == 3)
        // The working tree is sent as it is, without what Git ignores.
        #expect(lines.contains("files: ../changed ../committed ../link ../untracked "))
        #expect(lines.contains("link: committed"))
        // The host's folders are shown as this Mac's.
        let local = checkout.root.path(percentEncoded: false)
        #expect(lines.contains("directory: \(local)/App/Empty"))
        #expect(lines.contains("Log: \(outputDirectory.path(percentEncoded: false))/Job/xcodebuild.log"))
        let cache = storage.compilationCacheDirectory.appending(path: "remote").path(percentEncoded: false)
        #expect(lines.contains("arguments: build --output-directory=\(outputDirectory.path(percentEncoded: false)) --compilation-cache=\(cache) --scheme=App -- -quiet"))
        #expect(try String(contentsOf: outputDirectory.appending(path: "Job/xcodebuild.log"), encoding: .utf8) == "the log of \(local)/App/Empty\n")
        #expect(try String(contentsOf: outputDirectory.appending(path: "Job/Results.xcresult/Info.plist"), encoding: .utf8) == "the results\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path(percentEncoded: false)).sorted() == ["Job"])
        // The host keeps the compiler cache and nothing else.
        try await waitUntil { remoteFolders(in: storage).isEmpty }

        await host.management.shutDown()
    }

    @Test func aHostDispatchesAnUncommittedCheckoutToItsNextAvailableRunner() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, storage, shown, endpoint, directory) = try await hostAndCheckout(at: root)
        let worker = managedMac(named: "Runner", at: root.appending(path: "Runner"), operationTool: try operationTool(at: root))
        worker.storageDidBecomeAvailable(try worker.installation.initializeStorage())
        try await host.pool.configure(maximumConcurrentJobs: 1)
        try await worker.pool.configure(maximumConcurrentJobs: 1)
        let paired = try await pair(host.managedMacs, with: worker.management)
        try await waitUntil { worker.management.managementPort != nil }
        await host.managedMacs.checkStatus(of: paired.id, at: try local(worker.management.managementPort))

        let checkout = try await Checkout.containing(directory.appending(path: "App/Empty"))
        let output = root.appending(path: "Output")
        let received = Output()
        let occupied = Task { try await worker.pool.withSlot { try await Task.sleep(for: .seconds(60)) } }
        defer { occupied.cancel() }
        try await waitUntil { try await worker.pool.status()?.activeJobCount == 1 }
        try await host.pool.withSlot {
            let contacts = Mutex(0)
            let result = try await RemoteOperationClient.run(
                ["build", "--scheme=App"], in: checkout, hosts: [shown], automatic: true, outputDirectory: output,
                endpoint: { _ in
                    let number = contacts.withLock { $0 += 1; return $0 }
                    if number == 2 {
                        occupied.cancel()
                        _ = await occupied.result
                    }
                    return endpoint
                }, output: { received.append($0) }
            )
            #expect(result == 3)
            #expect(contacts.withLock { $0 } >= 2)
        }
        #expect(received.text.contains(worker.installation.homeDirectory.path(percentEncoded: false)))
        #expect(received.text.contains("files: ../changed ../committed ../link ../untracked "))
        #expect(received.text.contains("contents: changed"))
        #expect(try String(contentsOf: output.appending(path: "Job/Results.xcresult/Info.plist"), encoding: .utf8) == "the results\n")
        try await waitUntil { try await worker.pool.status()?.activeJobCount == 0 }

        // The host can reserve a slot, but its runner volume is no longer mounted.
        try FileManager.default.removeItem(at: storage.directory)
        let rerouted = Output()
        let nextStatus = try await RemoteOperationClient.run(
            "build", arguments: [], in: checkout, on: shown, at: endpoint, outputDirectory: root.appending(path: "Rerouted"),
            automatic: true
        ) { rerouted.append($0) }
        #expect(nextStatus == 3)
        #expect(rerouted.text.contains(worker.installation.homeDirectory.path(percentEncoded: false)))

        host.setPaused(true)
        let testing = Output()
        let test = Task {
            try await RemoteOperationClient.run(
                ["test"], in: checkout, hosts: [shown], automatic: true, outputDirectory: output, endpoint: { _ in endpoint }
            ) { testing.append($0) }
        }
        try await waitUntil { testing.text.contains("started\n") }
        #expect(try await worker.pool.status()?.activeJobCount == 1)
        test.cancel()
        await #expect(throws: (any Error).self) { try await test.value }
        try await waitUntil { try await worker.pool.status()?.activeJobCount == 0 }

        await worker.management.shutDown()
        await host.managedMacs.shutDown()
        await host.management.shutDown()
    }

    @Test func aDashboardReportsAnInvalidResultBundle() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, _, shown, endpoint, directory) = try await hostAndCheckout(at: root)
        try Data().write(to: directory.appending(path: "bundle-with-alias"))
        let checkout = try await Checkout.containing(directory)
        let failure = await #expect(throws: RemoteOperationFailure.self) {
            try await RemoteOperationClient.run(
                "build", arguments: [], in: checkout, on: shown, at: endpoint, outputDirectory: root.appending(path: "Output")
            ) { _ in }
        }
        let output = root.appending(path: "Output")
        let saved = try #require(FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).first)
        let message = try #require(failure?.message)
        #expect(message.contains("Unexpected file type in the result bundle: InfoAlias."))
        #expect(message.contains("\(saved.lastPathComponent)/results.tar"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: saved.path(percentEncoded: false)) == ["results.tar"])
        await host.management.shutDown()
    }

    @Test func aCheckoutRelativeXcodeDefersTheDestinationCheckUntilTransfer() async throws {
        func operation(_ selection: String...) -> RemoteOperation {
            RemoteOperation(repository: "Project", name: "Project", directory: "", action: "test",
                            arguments: selection + ["--destination=id=\(UUID().uuidString)"])
        }
        try await operation("--developer-directory", "").checkDestination(savedXcode: nil, allowRuntimeDownload: false)
        await #expect(throws: RemoteOperationFailure.self) {
            try await operation("--environment=DEVELOPER_DIR=").checkDestination(savedXcode: nil, allowRuntimeDownload: false)
        }
    }

    @Test func aHostRefusesAnOperationWhileItIsPausedOrItsStorageIsMissing() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, storage, shown, endpoint, directory) = try await hostAndCheckout(at: root)
        let checkout = try await Checkout.containing(directory)
        host.setPaused(true)
        await #expect(throws: HostLinkError.refused("Managed is paused and takes no new jobs.")) {
            try await RemoteOperationClient.run(
                "build", arguments: [], in: checkout, on: shown, at: endpoint, outputDirectory: root.appending(path: "Output")
            ) { _ in }
        }
        host.setPaused(false)
        // As when the volume that holds the storage is not mounted.
        try FileManager.default.removeItem(at: storage.directory)

        await #expect(throws: HostLinkError.refused("\(HostPane.macName)'s storage is not available at \(storage.directory.path(percentEncoded: false)).")) {
            try await RemoteOperationClient.run(
                "build", arguments: [], in: checkout, on: shown, at: endpoint, outputDirectory: root.appending(path: "Output")
            ) { _ in }
        }
        host.hostState = .running
        let slots = await host.readRunnerSlots()
        #expect(slots.state == "unavailable")
        #expect(slots.reason?.contains(storage.directory.path(percentEncoded: false)) == true)
        #expect(HostSettingsReport(host).runnerSlots == slots)
        try await host.pool.configure(maximumConcurrentJobs: 1)
        try await host.pool.withSlot {
            let failure = await #expect(throws: HostAvailability.self) {
                try await RemoteOperationClient.run("test", arguments: [], in: checkout, on: shown, at: endpoint,
                                                    outputDirectory: root.appending(path: "Output"), automatic: true) { _ in }
            }
            guard case .unavailable(let message) = failure else { Issue.record("Missing storage reported as busy"); return }
            #expect(message.contains(storage.directory.path(percentEncoded: false)))
        }
        #expect(!FileManager.default.fileExists(atPath: storage.directory.path(percentEncoded: false)))

        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        _ = try host.installation.initializeStorage()
        let coordinator = try FileHandle(forUpdating: host.pool.directory.appending(path: "pool.lock"))
        try #require(flock(coordinator.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
        let refresh = Task { await host.refreshPoolStatus() }
        try await waitUntil { host.runnerSlots == .contended }
        let updating = await host.readRunnerSlots()
        #expect(updating.state == "unknown")
        #expect(updating.available == nil)
        #expect(updating.reason == "The execution pool is being updated.")
        try coordinator.close()
        await refresh.value
        #expect(await host.readRunnerSlots().available == 1)
        try await host.pool.withSlot {
            let recovered = await host.readRunnerSlots()
            #expect(recovered == RunnerSlots(state: "busy", limit: 1))
            #expect(await MainActor.run { HostSettingsReport(host).runnerSlots } == recovered)
        }
        await host.management.shutDown()
    }

    @Test func aHostStopsAnOperationWhenTheDashboardLeaves() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, storage, shown, endpoint, directory) = try await hostAndCheckout(at: root)
        let checkout = try await Checkout.containing(directory)
        let outputDirectory = root.appending(path: "Output")

        let received = Output()
        let test = Task {
            try await RemoteOperationClient.run(
                "test", arguments: [], in: checkout, on: shown, at: endpoint, outputDirectory: outputDirectory
            ) { received.append($0) }
        }
        try await waitUntil { received.text.contains("started\n") }
        #expect(received.text.contains("folder: 0\n"))

        // A second operation on the repository gets a folder of its own while the first one runs.
        let overlapping = Output()
        _ = try await RemoteOperationClient.run(
            "build", arguments: [], in: checkout, on: shown, at: endpoint, outputDirectory: outputDirectory
        ) { overlapping.append($0) }
        #expect(overlapping.text.contains("folder: 1\n"))

        test.cancel()
        await #expect(throws: (any Error).self) { try await test.value }
        let stopped = root.appending(path: "Home/Library/Application Support/XcodeRunnerKit/stopped")
        try await waitUntil { FileManager.default.fileExists(atPath: stopped.path(percentEncoded: false)) }
        try await waitUntil { remoteFolders(in: storage).isEmpty }

        await host.management.shutDown()
    }

    @Test func macsThatRunDifferentVersionsWorkTogether() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let managerStore = MemorySecretStore()
        let managed = managedMac(at: root)
        let management = managed.management
        let macs = PairedMacs(store: managerStore, name: "Manager", role: .manager, browses: false)
        let mac = try await pair(macs, with: management)
        try await waitUntil { management.managementPort != nil }
        let endpoint = try local(management.managementPort)

        let installation = RunnerProvisioner.InstallationRequest(
            repository: GitHubRepository(id: 1, fullName: "owner/Project"), runnerName: "runner", archive: root,
            sha256Checksum: "", registrationToken: "test-token", labels: [], replaceRegistration: false
        )
        let answer = try await HostLink.send(
            .runners(.install(installation)), to: endpoint, key: mac.pairing.symmetricKey, identity: mac.id.uuidString, version: 8
        )
        guard case .refused(let reason) = answer, reason.contains("Update the managing Mac") else {
            Issue.record("Expected the Mac to ask for a manager that checks fork workflow approval.")
            return
        }

        // The managing host is updated first, and still reads and changes the Mac.
        let updated = PairedMacs(
            store: managerStore, name: "Manager", role: .manager, browses: false, version: HostLink.version + 1
        )
        await updated.checkStatus(of: mac.id, at: endpoint)
        #expect(updated.status(of: mac.id) == .online)
        #expect(management.versionMismatches.isEmpty)
        let settings = try #require(updated.settings[mac.id])
        settings.runnerLabelsInput = "fast"
        #expect(await updated.saveRunnerLabels(of: mac.id))
        #expect(managed.runnerLabels == ["fast"])

        // A request that only the newer version has fails by itself, and the Mac answers the next one.
        let connection = NetworkConnection(
            to: endpoint,
            using: .parameters(initialParameters: HostLink.tlsParameters(key: mac.pairing.symmetricKey, identity: mac.id.uuidString)) {
                Coder(sending: Versioned<LaterRequest>.self, receiving: Versioned<HostLinkReply>.self, using: .json) { TCP() }
            }
        )
        try await connection.send(Versioned(LaterRequest.later, version: HostLink.version + 1))
        let unknown = try await connection.receive().content
        #expect(unknown.version == HostLink.version)
        guard case .unsupported? = unknown.payload else {
            Issue.record("The Mac answered a request that it cannot read with \(String(describing: unknown.payload))")
            return
        }
        try await connection.send(Versioned(LaterRequest.settings(.read), version: HostLink.version + 1))
        guard case .settings? = try await connection.receive().content.payload else {
            Issue.record("The Mac did not answer the request after the one that it could not read")
            return
        }

        // A message that only the newer version has is answered the same way after a request that takes several.
        let key = SymmetricKey(size: .bits256)
        let waiting = try await listener(key: key) { _, reply, next in
            _ = try await next()
            try await reply(.completed)
        }
        let following = NetworkConnection(
            to: waiting.endpoint, using: .parameters(initialParameters: HostLink.tlsParameters(key: key, identity: "listener")) {
                Coder(sending: Versioned<LaterRequest>.self, receiving: Versioned<HostLinkReply>.self, using: .json) { TCP() }
            }
        )
        try await following.send(Versioned(LaterRequest.settings(.read), version: HostLink.version + 1))
        try await following.send(Versioned(LaterRequest.later, version: HostLink.version + 1))
        guard case .unsupported? = try await following.receive().content.payload else {
            Issue.record("The Mac did not say that it cannot read a following message")
            return
        }
        waiting.task.cancel()

        // The newer Mac names the Mac to update for the request that its version does not have.
        let older = try await listener(key: key) { _, reply, _ in try await reply(.unsupported) }
        await #expect(throws: HostLinkError.incompatible(.older)) {
            try await HostLink.send(
                .settings(.read), to: older.endpoint, key: key, identity: "listener", version: HostLink.version + 1
            )
        }
        older.task.cancel()

        // Macs of different versions pair.
        let other = HostManagement(store: MemorySecretStore(), name: "Other", advertises: false)
        let paired = try await pair(updated, with: other)
        #expect(other.manager?.id == paired.id)
        await other.shutDown()

        await management.shutDown()
        await macs.shutDown()
        await updated.shutDown()
    }

    @Test func aMacWhoseVersionIsNotReadSaysWhichOneToUpdate() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let managerStore = MemorySecretStore()
        let managed = managedMac(at: root)
        let management = managed.management
        let macs = PairedMacs(store: managerStore, name: "Manager", role: .manager, browses: false)
        let mac = try await pair(macs, with: management)
        try await waitUntil { management.managementPort != nil }
        let endpoint = try local(management.managementPort)

        // The Mac is updated, and the managing host still runs a version from before the Mac's oldest one. The Mac
        // does not answer it, and each Mac names the other one's version.
        let outdated = PairedMacs(
            store: managerStore, name: "Manager", role: .manager, browses: false, version: HostLink.oldestVersion - 1
        )
        await outdated.checkStatus(of: mac.id, at: endpoint)
        #expect(outdated.status(of: mac.id) == .incompatible(.newer))
        #expect(management.versionMismatches == [mac.id: .older])
        #expect(outdated.settings[mac.id]?.report == nil)

        // The pairing is kept, so the Macs connect again once the managing host is updated.
        await macs.checkStatus(of: mac.id, at: endpoint)
        #expect(macs.status(of: mac.id) == .online)
        #expect(management.versionMismatches.isEmpty)

        // A Mac that waits to pair with such a version is listed with the reason, and does not pair.
        macs.discoverPairableMacs()
        macs.pairableMacsChanged([
            .init(id: "waiting", name: "Waiting", endpoint: endpoint, version: HostLink.oldestVersion - 1),
        ])
        #expect(macs.waitingMacs == [WaitingMac(id: "waiting", name: "Waiting", mismatch: .older)])
        await #expect(throws: HostLinkError.incompatible(.older)) { try await macs.pair(with: "waiting") }
        // A Mac that waits refuses a Mac of such a version that asks without having listed it.
        let other = HostManagement(store: MemorySecretStore(), name: "Other", advertises: false)
        let waiting = try await waitToPair(other)
        await #expect(throws: HostLinkError.refused("Other runs a newer version of XcodeHomeRunner. Update Manager to pair.")) {
            try await outdated.pair(at: waiting)
        }
        #expect(other.manager == nil)
        await other.shutDown()

        await management.shutDown()
        await macs.shutDown()
        await outdated.shutDown()
    }

    @Test func aReportFromANewerVersionIsReadWithWhatThisVersionDoesNotKnow() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = managedMac(at: root)
        managed.runners = [
            RunnerSettingsRow(directory: root.appending(path: "runner"), name: "runner", state: .running, configurationError: nil),
        ]
        var report = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(HostSettingsReport(managed))) as? [String: Any]
        )
        // A newer version adds a value, and names states that this version does not have.
        report["laterValue"] = ["enabled": true]
        report["hostState"] = "Updating"
        var runner = try #require((report["runners"] as? [[String: Any]])?.first)
        runner["state"] = "Draining"
        report["runners"] = [runner]

        let read = try JSONDecoder().decode(HostSettingsReport.self, from: JSONSerialization.data(withJSONObject: report))
        #expect(read.hostState.rawValue == "Updating")
        #expect(read.runners.map(\.state.rawValue) == ["Draining"])
        #expect(read.runners.map(\.name) == ["runner"])
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

/// The requests of a later version: one that this version does not have, and one that it has.
private enum LaterRequest: Codable, Sendable {
    case later
    case settings(HostSettingsRequest)
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

/// An operation's output as the dashboard received it.
private final class Output: Sendable {
    private let data = Mutex(Data())

    func append(_ output: Data) { data.withLock { $0.append(output) } }

    var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
}
