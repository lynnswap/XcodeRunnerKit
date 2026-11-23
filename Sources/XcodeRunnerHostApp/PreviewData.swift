#if DEBUG
import AppKit
import Foundation
import Network
import Synchronization
import XcodeRunnerHostSupport
import XcodeRunnerKit

/// Keeps preview sign-ins and pairings out of the Keychain.
final class PreviewSecretStore: SecretStore {
    private let data = Mutex<Data?>(nil)

    func read() -> Data? { data.withLock { $0 } }
    func write(_ data: Data) { self.data.withLock { $0 = data } }
    func insert(_ value: Data) throws {
        try data.withLock {
            guard $0 == nil else { throw CocoaError(.fileWriteFileExists) }
            $0 = value
        }
    }
    func remove() { data.withLock { $0 = nil } }
}

/// What the previews show: Macs whose settings are in temporary folders, with GitHub answered in memory and without
/// Bonjour.
@MainActor
enum HostPreview {
    /// The Macs that previews list under Runners.
    static let managedMacs = ["MacBook Air", "Mac Studio"].enumerated().map { index, name in
        PairedMac(
            pairing: HostPairing(id: UUID(uuidString: "6F1C0B7E-2D7A-4C55-9E0B-3E0D2B7C1A0\(index)")!, name: name, key: Data(count: 32)),
            hostID: UUID()
        )
    }

    enum Pairing {
        case none
        case managing
        /// Manages the preview Macs, and the first one answers until it `stopsAnswering`.
        case managingConnected(stopsAnswering: Bool)
        case managed(by: String)
        case waitingToPair
        /// Another Mac asks to manage this one.
        case asked(by: String)
        /// Manages the preview Macs while other Macs show this one.
        case shown(on: [String])
        /// Another Mac asks to show this one.
        case askedToShow(by: String)
    }

    /// The Xcodes that the previews' Macs list, in place of the ones on the Mac that shows the preview.
    static let xcodes = [
        InstalledXcode(application: URL(filePath: "/Applications/Xcode_27.2.app"), version: "27.2", build: "27B48"),
        InstalledXcode(application: URL(filePath: "/Applications/Xcode_26.6.app"), version: "26.6", build: "17F42"),
    ]

    /// A host window's content, which shows `pane` of a Mac with `settings(isSignedIn:pairing:isPaused:savedXcodeIsRemoved:)`.
    static func hostWindow(
        pane: HostPane, isSignedIn: Bool, pairing: Pairing = .none, isPaused: Bool = false, savedXcodeIsRemoved: Bool = false
    ) -> HostSplitViewController {
        let settings = settings(
            isSignedIn: isSignedIn, pairing: pairing, isPaused: isPaused, savedXcodeIsRemoved: savedXcodeIsRemoved
        )
        return HostSplitViewController(model: HostWindowModel(settings: settings, pane: pane))
    }

    /// A Mac's settings.
    ///
    /// - Parameter savedXcodeIsRemoved: Whether the Mac's saved Xcode is none of the ones that it lists.
    static func settings(
        isSignedIn: Bool, pairing: Pairing = .none, isPaused: Bool = false, savedXcodeIsRemoved: Bool = false
    ) -> HostSettingsModel {
        let installation = HostInstallation(homeDirectory: .temporaryDirectory.appending(path: UUID().uuidString))
        let github = gitHubSettings(installation: installation, isSignedIn: isSignedIn)
        let managingHost = PreviewSecretStore()
        let managedMacStore = PreviewSecretStore()
        switch pairing {
        case .managing, .managingConnected: try? managedMacStore.write(JSONEncoder().encode(managedMacs))
        case .managed(let name):
            let manager = HostPairing(id: UUID(), name: name, key: Data(count: 32))
            try? managingHost.write(JSONEncoder().encode(HostManagement.Record(hostID: UUID(), manager: manager)))
        case .shown(let names):
            try? managedMacStore.write(JSONEncoder().encode(managedMacs))
            let dashboards = names.map { HostPairing(id: UUID(), name: $0, key: Data(count: 32)) }
            try? managingHost.write(JSONEncoder().encode(HostManagement.Record(hostID: UUID(), dashboards: dashboards)))
        case .none, .waitingToPair, .asked, .askedToShow: break
        }
        if savedXcodeIsRemoved {
            // An app in the Mac's temporary folder is on no Mac that shows the preview.
            let removed = InstalledXcode(
                application: installation.applicationsDirectory.appending(path: "Xcode_26.5.app"), version: "26.5", build: nil
            )
            _ = try? installation.saveDeveloperDirectory(removed.developerDirectory)
        }
        let settings = HostSettingsModel(
            installation: installation, github: github,
            management: HostManagement(store: managingHost, name: HostPane.macName, advertises: false),
            managedMacs: PairedMacs(store: managedMacStore, name: HostPane.macName, role: .manager, browses: false),
            installedXcodes: { [xcodes] in xcodes }
        )
        switch pairing {
        case .waitingToPair: settings.management.allowManagement()
        case .asked(let name):
            requestPairing(
                from: PairedMacs(store: PreviewSecretStore(), name: name, role: .manager, browses: false), with: settings.management
            )
        case .askedToShow(let name):
            requestPairing(
                from: PairedMacs(store: PreviewSecretStore(), name: name, role: .dashboard, browses: false), with: settings.management
            )
        case .managingConnected(let stopsAnswering):
            connect(managedMacs[0], to: settings.managedMacs, stopsAnswering: stopsAnswering)
        case .none, .managing, .managed, .shown: break
        }
        settings.hostState = .running
        settings.storageDidBecomeAvailable(HostInstallation.Storage(directory: installation.hostRoot.appending(path: "Storage")))
        if isPaused { settings.setPaused(true) }
        if isSignedIn {
            settings.runners = [
                RunnerSettingsRow(directory: installation.runnersRoot.appending(path: "1"), name: "Mac-mini-XcodeRunnerKit-1", state: isPaused ? .finishing : .running, configurationError: nil),
                RunnerSettingsRow(directory: installation.runnersRoot.appending(path: "2"), name: "Mac-mini-App-1", state: isPaused ? .paused : .starting, configurationError: nil),
            ]
        }
        Task {
            await settings.configureDefaultPool()
            await settings.refreshPoolStatus()
            await github.restore()
        }
        return settings
    }

    /// GitHub settings that are answered in memory, with two selected repositories when signed in.
    static func gitHubSettings(installation: HostInstallation, isSignedIn: Bool) -> GitHubHostSettings {
        let repositories = #"{"repositories":[{"id":1,"full_name":"lynnswap/XcodeHomeRunner"},{"id":2,"full_name":"example/App"},{"id":3,"full_name":"example/Website"}]}"#
        let store = PreviewSecretStore()
        if isSignedIn {
            try? GitHubHostConfiguration(repositories: [
                GitHubRepository(id: 1, fullName: "lynnswap/XcodeHomeRunner"), GitHubRepository(id: 2, fullName: "example/App"),
            ]).save(to: installation.hostRoot.appending(path: "github-host.json"))
            try? store.write(JSONEncoder().encode(GitHubCredentials(
                clientID: GitHubApp.xcodeHomeRunner.clientID, account: GitHubAccount(id: 1, login: "lynnswap"), accessToken: "preview",
                refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil
            )))
        }
        let client = GitHubClient(transport: { request in
            let body = request.url?.path == "/user/installations" ? #"{"installations":[{"id":1}]}"# : repositories
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        return GitHubHostSettings(
            installation: installation, pool: HostExecutionPool(directory: installation.poolDirectory), client: client,
            authentication: GitHubAuthentication(clientID: GitHubApp.xcodeHomeRunner.clientID, client: client, store: store),
            openURL: { _ in false }
        )
    }

    /// Answers as `mac` over the loopback interface with its own settings, and has `macs` read them as browsing does.
    ///
    /// - Parameter managing: A Mac that the answering Mac manages, which a dashboard then lists under it.
    static func connect(_ mac: PairedMac, to macs: PairedMacs, stopsAnswering: Bool, managing managed: PairedMac? = nil) {
        let store = PreviewSecretStore()
        let pairing = HostPairing(id: mac.id, name: HostPane.macName, key: mac.pairing.key)
        let record = switch macs.role {
        case .manager: HostManagement.Record(hostID: mac.hostID, manager: pairing)
        case .dashboard: HostManagement.Record(hostID: mac.hostID, dashboards: [pairing])
        }
        try? store.write(JSONEncoder().encode(record))
        let installation = HostInstallation(homeDirectory: .temporaryDirectory.appending(path: UUID().uuidString))
        let managedMacs = PreviewSecretStore()
        if let managed { try? managedMacs.write(JSONEncoder().encode([managed])) }
        let settings = HostSettingsModel(
            installation: installation, github: gitHubSettings(installation: installation, isSignedIn: true),
            management: HostManagement(store: store, name: mac.name, advertises: false),
            managedMacs: PairedMacs(store: managedMacs, name: mac.name, role: .manager, browses: false)
        )
        if let managed { connect(managed, to: settings.managedMacs, stopsAnswering: false) }
        settings.hostState = .running
        settings.storageDidBecomeAvailable(HostInstallation.Storage(directory: installation.hostRoot.appending(path: "Storage")))
        settings.runners = [
            RunnerSettingsRow(directory: installation.runnersRoot.appending(path: "1"), name: "\(mac.name)-XcodeRunnerKit-1", state: .running, configurationError: nil),
        ]
        settings.management.start()
        Task {
            await settings.configureDefaultPool()
            await settings.refreshPoolStatus()
            await settings.github.restore()
            // The preview shows the Mac as not found if it cannot listen.
            while settings.management.ports[mac.id] == nil {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard let port = settings.management.ports[mac.id] else { return }
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            await macs.checkStatus(of: mac.id, at: endpoint)
            if stopsAnswering {
                await settings.management.shutDown()
                await macs.checkStatus(of: mac.id, at: endpoint)
            } else {
                // The task keeps the Mac's settings, which its pairing listener answers from, while the preview shows it.
                do { try await Task.sleep(for: .seconds(3600)) } catch {}
            }
        }
    }

    /// Asks `management` to pair over the loopback interface, so that previews show both Macs' codes.
    static func requestPairing(from macs: PairedMacs, with management: HostManagement) {
        switch macs.role {
        case .manager: management.allowManagement()
        case .dashboard: management.allowDashboard()
        }
        Task {
            // The preview shows the request while both Macs wait, and shows nothing if it fails.
            do {
                while management.pairingWindow?.port == nil { try await Task.sleep(for: .milliseconds(10)) }
                guard let port = management.pairingWindow?.port else { return }
                try await macs.pair(at: .hostPort(host: "127.0.0.1", port: port))
            } catch {}
        }
    }

    /// The Mac that the dashboard's host manages.
    static let hostManagedMac = PairedMac(pairing: HostPairing(id: UUID(), name: "MacBook Air", key: Data(count: 32)), hostID: UUID())

    /// A dashboard window's content. Its host answers over the loopback interface unless it is `notFound`.
    static func dashboard(
        hasHost: Bool, notFound: Bool = false, pane: HostPane = .overview
    ) -> DashboardSplitViewController {
        let store = PreviewSecretStore()
        let host = PairedMac(pairing: HostPairing(id: UUID(), name: "Mac mini", key: Data(count: 32)), hostID: UUID())
        if hasHost { try? store.write(JSONEncoder().encode([host])) }
        let hosts = PairedMacs(store: store, name: HostPane.macName, role: .dashboard, browses: false)
        if hasHost, !notFound { connect(host, to: hosts, stopsAnswering: false, managing: hostManagedMac) }
        return DashboardSplitViewController(
            model: DashboardWindowModel(pairing: hosts, pane: pane)
        )
    }
}
#endif
