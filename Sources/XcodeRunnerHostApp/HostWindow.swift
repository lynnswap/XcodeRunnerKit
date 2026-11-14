import AppKit
import Observation
import SwiftUI
#if DEBUG
import Network
import Synchronization
import XcodeRunnerHostSupport
import XcodeRunnerKit
#endif

/// A pane in the host window's sidebar.
enum HostPane: Hashable {
    case overview
    case github
    /// This Mac's runner services and execution settings, listed under Runners.
    case mac
    /// A Mac that this host manages, listed under Runners.
    case managedMac(HostPairing.ID)

    @MainActor func title(in settings: HostSettingsModel) -> String {
        switch self {
        case .overview: "Overview"
        case .github: "GitHub"
        case .mac: Self.macName
        case .managedMac(let id): settings.managedMacs.mac(id)?.name ?? "Mac"
        }
    }

    var icon: SidebarRow.Icon {
        switch self {
        case .overview: .symbol("gauge.with.dots.needle.50percent")
        case .github: .template("github-mark")
        case .mac, .managedMac: .symbol("desktopcomputer")
        }
    }

    /// The computer name set in Sharing settings.
    static let macName = Host.current().localizedName ?? "This Mac"
}

/// What the host window shows.
@MainActor @Observable
final class HostWindowModel {
    /// The pane that is selected in the sidebar. A pane always stays selected.
    var pane = HostPane.overview
}

/// The host window's content: this Mac's panes and the Macs that it manages in a sidebar beside the selected pane, with
/// Add Mac in the toolbar.
@MainActor
final class HostSplitViewController: PaneSplitViewController {
    private let settings: HostSettingsModel
    private let model: HostWindowModel
    private var shownPane: HostPane?

    init(settings: HostSettingsModel, model: HostWindowModel = HostWindowModel()) {
        self.settings = settings
        self.model = model
        func row(_ pane: HostPane) -> SidebarRow { SidebarRow(pane: pane, title: pane.title(in: settings), icon: pane.icon) }
        let sidebar = SidebarViewController(
            groups: {
                [
                    SidebarGroup(title: nil, rows: [row(.overview), row(.github)]),
                    SidebarGroup(title: "Runners", rows: [row(.mac)] + settings.managedMacs.macs.map { row(.managedMac($0.id)) }),
                ]
            },
            selection: { model.pane },
            select: { if let pane = $0.base as? HostPane { model.pane = pane } }
        )
        super.init(sidebar: sidebar, autosaveName: "XcodeHomeRunnerSettings")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        update()
    }

    /// Shows the selected pane and names the window after it, then waits for the selection or the name to change.
    private func update() {
        let (pane, title) = withObservationTracking {
            (model.pane, model.pane.title(in: settings))
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
        self.title = title
        guard pane != shownPane else { return }
        shownPane = pane
        detail.show(makeViewController(for: pane))
    }

    private func makeViewController(for pane: HostPane) -> NSViewController {
        switch pane {
        case .overview:
            OverviewViewController(model: OverviewModel(settings: settings) { [model] in model.pane = .github })
        case .github: GitHubViewController(model: GitHubPaneModel(settings: settings))
        case .mac: MacViewController(model: MacPaneModel(settings: settings))
        case .managedMac(let id):
            MacViewController(model: MacPaneModel(
                macs: settings.managedMacs, id: id,
                // This Mac registers the Mac's runners, so a changed limit or label is applied to them here.
                registrationsChanged: { [settings] in await settings.github.synchronize() },
                removed: { [model] in model.pane = .mac }
            ))
        }
    }

    override var addMacToolTip: String {
        "Pair a Mac on the local network so that this Mac manages its runners. A Mac that another Mac manages cannot add Macs."
    }

    override var canAddMac: Bool { super.canAddMac && settings.canAddMacs }

    override func addMac(_ sender: Any?) {
        guard canAddMac else { return }
        presentAddMacSheet(for: settings.managedMacs) { [model] mac in model.pane = .managedMac(mac.id) }
    }
}

/// Creates the host window.
@MainActor
func makeHostWindowController(settings: HostSettingsModel) -> NSWindowController {
    makePaneWindowController(content: HostSplitViewController(settings: settings), autosaveName: "XcodeHomeRunnerSettings")
}

#if DEBUG
/// Keeps preview sign-ins and pairings out of the Keychain.
final class PreviewSecretStore: SecretStore {
    private let data = Mutex<Data?>(nil)

    func read() -> Data? { data.withLock { $0 } }
    func write(_ data: Data) { self.data.withLock { $0 = data } }
    func remove() { data.withLock { $0 = nil } }
}

/// The Macs that previews list under Runners.
private let previewManagedMacs = ["m1pro", "Mac Studio"].enumerated().map { index, name in
    PairedMac(
        pairing: HostPairing(id: UUID(uuidString: "6F1C0B7E-2D7A-4C55-9E0B-3E0D2B7C1A0\(index)")!, name: name, key: Data(count: 32)),
        hostID: UUID()
    )
}

private enum PreviewPairing {
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

/// A host window's content with settings in a temporary folder, GitHub answered in memory, and no Bonjour.
@MainActor
private func previewHostSplitViewController(
    pane: HostPane, isSignedIn: Bool, pairing: PreviewPairing = .none, isPaused: Bool = false
) -> HostSplitViewController {
    let installation = HostInstallation(homeDirectory: .temporaryDirectory.appending(path: UUID().uuidString))
    let github = previewGitHubSettings(installation: installation, isSignedIn: isSignedIn)
    let managingHost = PreviewSecretStore()
    let managedMacStore = PreviewSecretStore()
    switch pairing {
    case .managing, .managingConnected: try? managedMacStore.write(JSONEncoder().encode(previewManagedMacs))
    case .managed(let name):
        let manager = HostPairing(id: UUID(), name: name, key: Data(count: 32))
        try? managingHost.write(JSONEncoder().encode(HostManagement.Record(hostID: UUID(), manager: manager)))
    case .shown(let names):
        try? managedMacStore.write(JSONEncoder().encode(previewManagedMacs))
        let dashboards = names.map { HostPairing(id: UUID(), name: $0, key: Data(count: 32)) }
        try? managingHost.write(JSONEncoder().encode(HostManagement.Record(hostID: UUID(), dashboards: dashboards)))
    case .none, .waitingToPair, .asked, .askedToShow: break
    }
    let settings = HostSettingsModel(
        installation: installation, github: github,
        management: HostManagement(store: managingHost, name: HostPane.macName, advertises: false),
        managedMacs: PairedMacs(store: managedMacStore, name: HostPane.macName, role: .manager, browses: false)
    )
    switch pairing {
    case .waitingToPair: settings.management.allowManagement()
    case .asked(let name):
        requestPreviewPairing(
            from: PairedMacs(store: PreviewSecretStore(), name: name, role: .manager, browses: false), with: settings.management
        )
    case .askedToShow(let name):
        requestPreviewPairing(
            from: PairedMacs(store: PreviewSecretStore(), name: name, role: .dashboard, browses: false), with: settings.management
        )
    case .managingConnected(let stopsAnswering):
        connectPreviewMac(previewManagedMacs[0], to: settings.managedMacs, stopsAnswering: stopsAnswering)
    case .none, .managing, .managed, .shown: break
    }
    settings.hostState = .running
    settings.storageDidBecomeAvailable(HostInstallation.Storage(directory: installation.hostRoot.appending(path: "Storage")))
    if isPaused { settings.setPaused(true) }
    if isSignedIn {
        settings.runners = [
            RunnerSettingsRow(directory: installation.runnersRoot.appending(path: "1"), name: "m6mini-XcodeRunnerKit-1", state: isPaused ? .finishing : .running, configurationError: nil),
            RunnerSettingsRow(directory: installation.runnersRoot.appending(path: "2"), name: "m6mini-tweetpd-1", state: isPaused ? .paused : .starting, configurationError: nil),
        ]
    }
    Task {
        await settings.configureDefaultPool()
        await settings.refreshPoolStatus()
        await github.restore()
    }
    let model = HostWindowModel()
    model.pane = pane
    return HostSplitViewController(settings: settings, model: model)
}

/// GitHub settings that are answered in memory, with two selected repositories when signed in.
@MainActor
private func previewGitHubSettings(installation: HostInstallation, isSignedIn: Bool) -> GitHubHostSettings {
    let repositories = #"{"repositories":[{"id":1,"full_name":"lynnswap/XcodeRunnerKit"},{"id":2,"full_name":"lynnswap/tweetpd"},{"id":3,"full_name":"lynnswap/pd-site"}]}"#
    let store = PreviewSecretStore()
    if isSignedIn {
        try? GitHubHostConfiguration(repositories: [
            GitHubRepository(id: 1, fullName: "lynnswap/XcodeRunnerKit"), GitHubRepository(id: 2, fullName: "lynnswap/tweetpd"),
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
@MainActor
func connectPreviewMac(_ mac: PairedMac, to macs: PairedMacs, stopsAnswering: Bool, managing managed: PairedMac? = nil) {
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
        installation: installation, github: previewGitHubSettings(installation: installation, isSignedIn: true),
        management: HostManagement(store: store, name: mac.name, advertises: false),
        managedMacs: PairedMacs(store: managedMacs, name: mac.name, role: .manager, browses: false)
    )
    if let managed { connectPreviewMac(managed, to: settings.managedMacs, stopsAnswering: false) }
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
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

/// The Xcode section of a Mac whose saved Xcode was removed.
@MainActor
private struct XcodeSectionPreview: View {
    @Bindable var model: HostSettingsModel

    init() {
        let installation = HostInstallation(homeDirectory: .temporaryDirectory.appending(path: UUID().uuidString))
        try? installation.saveDeveloperDirectory(URL(filePath: "/Applications/Xcode_26.5.app/Contents/Developer"))
        model = HostSettingsModel(
            installation: installation, github: previewGitHubSettings(installation: installation, isSignedIn: false),
            management: HostManagement(store: PreviewSecretStore(), name: HostPane.macName, advertises: false),
            managedMacs: PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .manager, browses: false),
            installedXcodes: {
                [("27.2", "27B48", "Xcode_27.2"), ("26.6", "17F42", "Xcode_26.6")].map { version, build, name in
                    InstalledXcode(
                        developerDirectory: URL(filePath: "/Applications/\(name).app/Contents/Developer"), version: version, build: build
                    )
                }
            }
        )
    }

    var body: some View {
        Form {
            XcodeSection(
                settings: HostSettingsReport(model), selection: $model.xcodeSelectionInput, isSaving: model.isSavingXcode,
                saveError: model.xcodeSaveError, mac: .thisMac
            ) {
                Task { await model.saveXcodeSelection() }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Xcode Section") { XcodeSectionPreview() }
#Preview("Runner Labels Section") {
    @Previewable @State var labels = "fast, xcode-27"
    Form {
        RunnerLabelsSection(labels: $labels, isSaving: false, saveError: nil, mac: MacReference(name: "m1pro")) {}
    }
    .formStyle(.grouped)
}
#Preview("New Mac") { previewHostSplitViewController(pane: .overview, isSignedIn: false) }
#Preview("Overview") {
    previewHostSplitViewController(pane: .overview, isSignedIn: true, pairing: .managing)
}
#Preview("GitHub") { previewHostSplitViewController(pane: .github, isSignedIn: true) }
#Preview("GitHub Signed Out") { previewHostSplitViewController(pane: .github, isSignedIn: false) }
#Preview("Mac") { previewHostSplitViewController(pane: .mac, isSignedIn: true) }
#Preview("Paused Mac") {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, isPaused: true)
}
#Preview("Paused Overview") {
    previewHostSplitViewController(pane: .overview, isSignedIn: true, isPaused: true)
}
#Preview("Waiting to Pair") {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, pairing: .waitingToPair)
}
#Preview("Pairing Request") {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, pairing: .asked(by: "m6mini"))
}
#Preview("Managed by Another Mac") {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, pairing: .managed(by: "m6mini"))
}
#Preview("Shown on Dashboards") {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, pairing: .shown(on: ["MacBook Pro", "Mac Studio"]))
}
#Preview("Dashboard Pairing Request") {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, pairing: .askedToShow(by: "MacBook Pro"))
}
#Preview("Overview Managed by Another Mac") {
    previewHostSplitViewController(pane: .overview, isSignedIn: true, pairing: .managed(by: "m6mini"))
}
#Preview("Managed Mac") {
    previewHostSplitViewController(
        pane: .managedMac(previewManagedMacs[0].id), isSignedIn: true, pairing: .managingConnected(stopsAnswering: false)
    )
}
#Preview("Managed Mac Not Responding") {
    previewHostSplitViewController(
        pane: .managedMac(previewManagedMacs[0].id), isSignedIn: true, pairing: .managingConnected(stopsAnswering: true)
    )
}
#Preview("Managed Mac Not Found") {
    previewHostSplitViewController(pane: .managedMac(previewManagedMacs[0].id), isSignedIn: true, pairing: .managing)
}
#endif
