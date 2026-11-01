import AppKit
import SwiftUI
#if DEBUG
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

    var title: String {
        switch self {
        case .overview: "Overview"
        case .github: "GitHub"
        case .mac: Self.macName
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .github: "person.crop.circle"
        case .mac: "desktopcomputer"
        }
    }

    /// The computer name set in Sharing settings.
    static let macName = Host.current().localizedName ?? "This Mac"
}

@MainActor @Observable
final class HostWindowNavigation {
    var pane = HostPane.overview
}

/// Creates the host window: a sidebar of panes beside the selected pane.
@MainActor
func makeHostWindow(settings: HostSettingsModel) -> NSWindow {
    let navigation = HostWindowNavigation()
    let window = NSWindow(contentViewController: makeHostSplitViewController(settings: settings, navigation: navigation))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.title = navigation.pane.title
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 760, height: 620))
    window.contentMinSize = NSSize(width: 640, height: 420)
    window.setFrameAutosaveName("XcodeHomeRunnerSettings")
    window.center()
    return window
}

@MainActor
private func makeHostSplitViewController(settings: HostSettingsModel, navigation: HostWindowNavigation) -> NSSplitViewController {
    let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: HostSidebar(navigation: navigation)))
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
    let navigation: HostWindowNavigation

    var body: some View {
        // A sidebar click can deselect the row; a pane always stays selected.
        let selection = Binding<HostPane?>(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })
        List(selection: selection) {
            row(.overview)
            row(.github)
            Section("Runners") {
                row(.mac)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ pane: HostPane) -> some View {
        Label(pane.title, systemImage: pane.systemImage).tag(pane)
    }
}

@MainActor
private struct HostPaneView: View {
    let settings: HostSettingsModel
    let navigation: HostWindowNavigation

    var body: some View {
        Group {
            switch navigation.pane {
            case .overview: HostOverviewView(model: settings, navigation: navigation)
            case .github: GitHubSettingsView(model: settings.github).disabled(settings.isSaving)
            case .mac: HostMacSettingsView(model: settings)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(navigation.pane.title)
        .frame(minWidth: 440, minHeight: 420)
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
            Section(HostPane.macName) {
                LabeledContent("Status") {
                    Label {
                        Text(model.hostState.rawValue)
                    } icon: {
                        Image(systemName: model.hostState.systemImage).foregroundStyle(model.hostState.tint)
                    }
                }
                LabeledContent("Xcode jobs") { Text(jobSummary).monospacedDigit() }
                Text(model.admissionMessage).font(.callout).foregroundStyle(.secondary)
                if let error = model.storageError { ErrorText(error) }
                if let error = model.poolError { ErrorText(error) }
            }
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

    private var jobSummary: String {
        guard let status = model.poolStatus else {
            if !model.hasLoadedPoolStatus { return "Checking…" }
            return model.poolError == nil ? "Not configured" : "Unavailable"
        }
        return "\(status.activeJobCount) running · \(status.waitingJobCount) waiting · Limit \(status.configuration.maximumConcurrentJobs)"
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
/// Keeps preview sign-ins out of the Keychain.
private final class PreviewCredentialStore: GitHubCredentialStore {
    private let data = Mutex<Data?>(nil)

    func read() -> Data? { data.withLock { $0 } }
    func write(_ data: Data) { self.data.withLock { $0 = data } }
    func remove() { data.withLock { $0 = nil } }
}

/// A host window's content with settings in a temporary folder and GitHub answered in memory.
@MainActor
private func previewHostSplitViewController(pane: HostPane, isSignedIn: Bool) -> NSSplitViewController {
    let installation = HostInstallation(homeDirectory: .temporaryDirectory.appending(path: UUID().uuidString))
    let repositories = #"{"repositories":[{"id":1,"full_name":"lynnswap/XcodeRunnerKit"},{"id":2,"full_name":"lynnswap/tweetpd"},{"id":3,"full_name":"lynnswap/pd-site"}]}"#
    let store = PreviewCredentialStore()
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
    let settings = HostSettingsModel(installation: installation, github: github)
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

#Preview("New Mac", traits: .fixedLayout(width: 760, height: 620)) { previewHostSplitViewController(pane: .overview, isSignedIn: false) }
#Preview("Overview", traits: .fixedLayout(width: 760, height: 620)) { previewHostSplitViewController(pane: .overview, isSignedIn: true) }
#Preview("GitHub", traits: .fixedLayout(width: 760, height: 620)) { previewHostSplitViewController(pane: .github, isSignedIn: true) }
#Preview("Mac", traits: .fixedLayout(width: 760, height: 620)) { previewHostSplitViewController(pane: .mac, isSignedIn: true) }
#endif
