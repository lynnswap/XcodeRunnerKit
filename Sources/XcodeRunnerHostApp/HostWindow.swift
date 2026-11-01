import AppKit
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

    var icon: Image {
        switch self {
        case .overview: Image(systemName: "gauge.with.dots.needle.50percent")
        case .github: Image("github-mark", bundle: .module)
        case .mac, .managedMac: Image(systemName: "desktopcomputer")
        }
    }

    /// The computer name set in Sharing settings.
    static let macName = Host.current().localizedName ?? "This Mac"
}

@MainActor @Observable
final class HostWindowNavigation {
    var pane = HostPane.overview
    var isAddingMac = false
}

/// Creates the host window: a sidebar of panes beside the selected pane.
@MainActor
func makeHostWindow(settings: HostSettingsModel) -> NSWindow {
    let navigation = HostWindowNavigation()
    let window = NSWindow(contentViewController: makeHostSplitViewController(settings: settings, navigation: navigation))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.title = navigation.pane.title(in: settings)
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 760, height: 620))
    window.contentMinSize = NSSize(width: 640, height: 420)
    window.setFrameAutosaveName("XcodeHomeRunnerSettings")
    window.center()
    return window
}

@MainActor
private func makeHostSplitViewController(settings: HostSettingsModel, navigation: HostWindowNavigation) -> NSSplitViewController {
    let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: HostSidebar(settings: settings, navigation: navigation)))
    sidebar.canCollapse = false
    sidebar.minimumThickness = 180
    let detail = NSHostingController(rootView: HostPaneView(settings: settings, navigation: navigation))
    // The selected pane's navigation title names the window. The window sets the first title because the bridge
    // does not apply it before the view is in the window.
    detail.sceneBridgingOptions = [.title]
    let split = NSSplitViewController()
    split.addSplitViewItem(sidebar)
    split.addSplitViewItem(NSSplitViewItem(viewController: detail))
    return split
}

@MainActor
private struct HostSidebar: View {
    let settings: HostSettingsModel
    let navigation: HostWindowNavigation

    var body: some View {
        // A sidebar click can deselect the row; a pane always stays selected.
        let selection = Binding<HostPane?>(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })
        List(selection: selection) {
            row(.overview)
            row(.github)
            Section("Runners") {
                row(.mac)
                ForEach(settings.managedMacs.macs) { mac in row(.managedMac(mac.id)) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add Mac…", systemImage: "plus.circle") { navigation.isAddingMac = true }
                    .buttonStyle(.borderless)
                    .disabled(!settings.canAddMacs)
                    .help(settings.canAddMacs ? "Pair a Mac on the local network so that this Mac manages its runners." : "This Mac is managed by another Mac, so it cannot add Macs.")
                    .accessibilityIdentifier("add-mac")
                Spacer()
            }
            .padding(10)
        }
    }

    private func row(_ pane: HostPane) -> some View {
        Label { Text(pane.title(in: settings)) } icon: { pane.icon }.tag(pane)
    }
}

@MainActor
private struct HostPaneView: View {
    let settings: HostSettingsModel
    let navigation: HostWindowNavigation

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            switch navigation.pane {
            case .overview: HostOverviewView(model: settings, navigation: navigation)
            case .github: GitHubSettingsView(model: settings.github).disabled(settings.isSaving)
            case .mac: HostMacSettingsView(model: settings)
            case .managedMac(let id):
                if let mac = settings.managedMacs.mac(id) {
                    ManagedMacView(macs: settings.managedMacs, mac: mac, navigation: navigation)
                } else {
                    ContentUnavailableView("This Mac was removed", systemImage: "desktopcomputer")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(navigation.pane.title(in: settings))
        .frame(minWidth: 440, minHeight: 420)
        .sheet(isPresented: $navigation.isAddingMac) {
            AddMacView(macs: settings.managedMacs) { pairing in
                navigation.isAddingMac = false
                navigation.pane = .managedMac(pairing.id)
            } cancel: {
                navigation.isAddingMac = false
            }
        }
    }
}

@MainActor
private struct HostOverviewView: View {
    let model: HostSettingsModel
    let navigation: HostWindowNavigation

    private var github: GitHubHostSettings { model.github }

    var body: some View {
        Form {
            if github.hasRestored && (github.account == nil || github.savedRepositoryIDs.isEmpty) {
                setup
            }
            Section(HostPane.macName) { HostStatusRows(settings: model) }
            Section("Repositories") {
                if github.isSynchronizing { ProgressView("Synchronizing runner registrations…") }
                if github.runnerStatuses.isEmpty && !github.isSynchronizing {
                    Text(github.savedRepositoryIDs.isEmpty
                        ? "No repositories are selected."
                        : "Runner counts appear after the next synchronization.")
                        .foregroundStyle(.secondary)
                }
                ForEach(github.runnerStatuses) { status in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(status.repository.fullName) {
                            Text("\(status.onlineCount) of \(status.desiredCount) online · \(status.busyCount) busy")
                                .monospacedDigit()
                        }
                        if let error = status.errorMessage { ErrorText(error) }
                        if status.excessCount > 0 {
                            Text("\(status.excessCount) extra registrations are retained to keep existing jobs running. The shared Xcode execution limit still applies.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = github.errorMessage { ErrorText(error) }
            }
        }
    }

    /// The first unfinished step offers its action, so the order of setup stays visible.
    private var setup: some View {
        let steps = [
            github.account != nil,
            !github.selectableRepositories.isEmpty,
            !github.savedRepositoryIDs.isEmpty,
        ]
        let current = steps.firstIndex(of: false)
        return Section("Get Started") {
            setupStep("Sign in to GitHub", isDone: steps[0], isCurrent: current == 0) {
                Button("Connect GitHub…") {
                    navigation.pane = .github
                    github.signIn()
                }
                .disabled(github.isBusy)
            }
            setupStep("Install the app on your repositories", isDone: steps[1], isCurrent: current == 1) {
                Button("Add Repositories on GitHub…") { github.installApp() }
                Button("Reload") { Task { await github.reloadRepositories() } }
                    .disabled(!github.canReloadRepositories)
            }
            setupStep("Choose the repositories to run", isDone: steps[2], isCurrent: current == 2) {
                Button("Choose Repositories…") { navigation.pane = .github }
            }
        }
    }

    private func setupStep(
        _ title: String, isDone: Bool, isCurrent: Bool, @ViewBuilder actions: () -> some View
    ) -> some View {
        LabeledContent {
            if isCurrent { HStack { actions() } }
        } label: {
            Label(title, systemImage: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? .secondary : .primary)
        }
    }

}

/// A Mac's host status and Xcode job counts, for this Mac or a Mac that this host manages.
@MainActor
struct HostStatusRows<Settings: HostSettingsDisplay>: View {
    let settings: Settings

    var body: some View {
        LabeledContent("Status") {
            Label {
                Text(settings.hostState.rawValue)
            } icon: {
                Image(systemName: settings.hostState.systemImage).foregroundStyle(settings.hostState.tint)
            }
        }
        LabeledContent("Xcode jobs") { Text(settings.jobSummary).monospacedDigit() }
        Text(settings.admissionMessage).font(.callout).foregroundStyle(.secondary)
        if let error = settings.storageError { ErrorText(error) }
        if let error = settings.poolError { ErrorText(error) }
    }
}

private extension HostState {
    var systemImage: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .starting, .preparingStorage: "circle.dotted"
        case .waitingForStorage: "clock"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .waitingForStorage: .orange
        case .needsAttention: .red
        case .starting, .preparingStorage, .stopping: .secondary
        }
    }
}

struct ErrorText: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
    }
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
    ManagedMac(
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
}

/// A host window's content with settings in a temporary folder, GitHub answered in memory, and no Bonjour.
@MainActor
private func previewHostSplitViewController(
    pane: HostPane, isSignedIn: Bool, pairing: PreviewPairing = .none
) -> NSSplitViewController {
    let installation = HostInstallation(homeDirectory: .temporaryDirectory.appending(path: UUID().uuidString))
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
    let pool = HostExecutionPool(directory: installation.poolDirectory)
    let github = GitHubHostSettings(
        installation: installation, pool: pool, client: client,
        authentication: GitHubAuthentication(clientID: GitHubApp.xcodeHomeRunner.clientID, client: client, store: store),
        openURL: { _ in false }
    )
    let managingHost = PreviewSecretStore()
    let managedMacStore = PreviewSecretStore()
    switch pairing {
    case .managing, .managingConnected: try? managedMacStore.write(JSONEncoder().encode(previewManagedMacs))
    case .managed(let name):
        let manager = HostPairing(id: UUID(), name: name, key: Data(count: 32))
        try? managingHost.write(JSONEncoder().encode(HostManagement.Record(hostID: UUID(), manager: manager)))
    case .none, .waitingToPair, .asked: break
    }
    let settings = HostSettingsModel(
        installation: installation, github: github,
        management: HostManagement(store: managingHost, name: HostPane.macName, advertises: false),
        managedMacs: ManagedMacs(store: managedMacStore, name: HostPane.macName, browses: false)
    )
    switch pairing {
    case .waitingToPair: settings.management.allowManagement()
    case .asked(let name):
        requestPreviewPairing(from: ManagedMacs(store: PreviewSecretStore(), name: name, browses: false), with: settings.management)
    case .managingConnected(let stopsAnswering):
        connectPreviewMac(previewManagedMacs[0], to: settings.managedMacs, stopsAnswering: stopsAnswering)
    case .none, .managing, .managed: break
    }
    settings.hostState = .running
    settings.storageDidBecomeAvailable(HostInstallation.Storage(directory: installation.hostRoot.appending(path: "Storage")))
    if isSignedIn {
        settings.runners = [
            RunnerSettingsRow(directory: installation.runnersRoot.appending(path: "1"), name: "m6mini-XcodeRunnerKit-1", state: .running, configurationError: nil),
            RunnerSettingsRow(directory: installation.runnersRoot.appending(path: "2"), name: "m6mini-tweetpd-1", state: .starting, configurationError: nil),
        ]
    }
    Task {
        await settings.configureDefaultPool()
        await settings.refreshPoolStatus()
        await github.restore()
    }
    let navigation = HostWindowNavigation()
    navigation.pane = pane
    let split = makeHostSplitViewController(settings: settings, navigation: navigation)
    return split
}

/// Answers as `mac` over the loopback interface with its own settings, and has `macs` read them as browsing does.
@MainActor
private func connectPreviewMac(_ mac: ManagedMac, to macs: ManagedMacs, stopsAnswering: Bool) {
    let store = PreviewSecretStore()
    let manager = HostPairing(id: mac.id, name: HostPane.macName, key: mac.pairing.key)
    try? store.write(JSONEncoder().encode(HostManagement.Record(hostID: mac.hostID, manager: manager)))
    let installation = HostInstallation(homeDirectory: .temporaryDirectory.appending(path: UUID().uuidString))
    let settings = HostSettingsModel(
        installation: installation,
        management: HostManagement(store: store, name: mac.name, advertises: false),
        managedMacs: ManagedMacs(store: PreviewSecretStore(), name: mac.name, browses: false)
    )
    settings.hostState = .running
    settings.storageDidBecomeAvailable(HostInstallation.Storage(directory: installation.hostRoot.appending(path: "Storage")))
    settings.runners = [
        RunnerSettingsRow(directory: installation.runnersRoot.appending(path: "1"), name: "m1pro-XcodeRunnerKit-1", state: .running, configurationError: nil),
    ]
    settings.management.start()
    Task {
        await settings.configureDefaultPool()
        await settings.refreshPoolStatus()
        // The preview shows the Mac as not found if it cannot listen.
        while settings.management.managementPort == nil {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
        guard let port = settings.management.managementPort else { return }
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

#Preview("New Mac", traits: .fixedLayout(width: 760, height: 620)) { previewHostSplitViewController(pane: .overview, isSignedIn: false) }
#Preview("Overview", traits: .fixedLayout(width: 760, height: 620)) {
    previewHostSplitViewController(pane: .overview, isSignedIn: true, pairing: .managing)
}
#Preview("GitHub", traits: .fixedLayout(width: 760, height: 620)) { previewHostSplitViewController(pane: .github, isSignedIn: true) }
#Preview("Mac", traits: .fixedLayout(width: 760, height: 620)) { previewHostSplitViewController(pane: .mac, isSignedIn: true) }
#Preview("Waiting to Pair", traits: .fixedLayout(width: 760, height: 620)) {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, pairing: .waitingToPair)
}
#Preview("Pairing Request", traits: .fixedLayout(width: 760, height: 620)) {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, pairing: .asked(by: "m6mini"))
}
#Preview("Managed by Another Mac", traits: .fixedLayout(width: 760, height: 620)) {
    previewHostSplitViewController(pane: .mac, isSignedIn: true, pairing: .managed(by: "m6mini"))
}
#Preview("Managed Mac", traits: .fixedLayout(width: 760, height: 620)) {
    previewHostSplitViewController(
        pane: .managedMac(previewManagedMacs[0].id), isSignedIn: true, pairing: .managingConnected(stopsAnswering: false)
    )
}
#Preview("Managed Mac Not Responding", traits: .fixedLayout(width: 760, height: 620)) {
    previewHostSplitViewController(
        pane: .managedMac(previewManagedMacs[0].id), isSignedIn: true, pairing: .managingConnected(stopsAnswering: true)
    )
}
#Preview("Managed Mac Not Found", traits: .fixedLayout(width: 760, height: 620)) {
    previewHostSplitViewController(pane: .managedMac(previewManagedMacs[0].id), isSignedIn: true, pairing: .managing)
}
#endif
