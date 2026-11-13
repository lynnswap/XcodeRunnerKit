import AppKit
import SwiftUI

/// The app opened without a host: a window that shows the hosts paired with this Mac.
///
/// It creates no runner folders or execution pool, registers no runners, and keeps only the pairings in the Keychain.
@MainActor
final class Dashboard: NSObject, NSApplicationDelegate {
    private let hosts: PairedMacs
    private var window: NSWindow?
    private var stopped = false

    init(hosts: PairedMacs) {
        self.hosts = hosts
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = Self.mainMenu()
        hosts.start()
        showWindow()
        print("Dashboard started.")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if stopped { return .terminateNow }
        Task {
            await hosts.shutDown()
            stopped = true
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func showWindow() {
        if window == nil { window = makeDashboardWindow(hosts: hosts) }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The menus that a window with text fields needs. The menu bar host has no menu bar of its own.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            for item in items { menu.addItem(item) }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        add("XcodeHomeRunner", [
            NSMenuItem(title: "Hide XcodeHomeRunner", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            .separator(),
            NSMenuItem(title: "Quit XcodeHomeRunner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        add("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        add("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        return main
    }
}

/// A pane in the dashboard window's sidebar, for one of the hosts.
enum DashboardPane: Hashable {
    case overview(HostPairing.ID)
    case github(HostPairing.ID)
    /// The host's runner services and execution settings.
    case mac(HostPairing.ID)
    /// A Mac that the host manages, which the dashboard reaches through the host.
    case managedMac(HostPairing.ID, host: HostPairing.ID)

    var host: HostPairing.ID {
        switch self {
        case .overview(let host), .github(let host), .mac(let host), .managedMac(_, let host): host
        }
    }
}

@MainActor @Observable
final class DashboardNavigation {
    /// What the Add Mac sheet pairs: this dashboard with a host, or a host with a Mac for it to manage.
    enum Addition: Hashable, Identifiable {
        case host
        case mac(managedBy: HostPairing.ID)

        var id: Self { self }
    }

    var pane: DashboardPane?
    var addition: Addition?
}

/// Creates the dashboard window: a sidebar of paired hosts and their panes beside the selected pane.
@MainActor
func makeDashboardWindow(hosts: PairedMacs) -> NSWindow {
    let window = NSWindow(contentViewController: makeDashboardSplitViewController(hosts: hosts, navigation: DashboardNavigation()))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.title = "XcodeHomeRunner"
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 760, height: 620))
    window.contentMinSize = NSSize(width: 640, height: 420)
    window.setFrameAutosaveName("XcodeHomeRunnerDashboard")
    window.center()
    return window
}

@MainActor
func makeDashboardSplitViewController(hosts: PairedMacs, navigation: DashboardNavigation) -> NSSplitViewController {
    if navigation.pane == nil { navigation.pane = hosts.macs.first.map { .overview($0.id) } }
    let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: DashboardSidebar(hosts: hosts, navigation: navigation)))
    sidebar.canCollapse = false
    sidebar.minimumThickness = 180
    let detail = NSHostingController(rootView: DashboardPaneView(hosts: hosts, navigation: navigation))
    // The selected pane's navigation title names the window, as the host window's panes do.
    detail.sceneBridgingOptions = [.title]
    let split = NSSplitViewController()
    split.addSplitViewItem(sidebar)
    split.addSplitViewItem(NSSplitViewItem(viewController: detail))
    return split
}

@MainActor
private struct DashboardSidebar: View {
    let hosts: PairedMacs
    let navigation: DashboardNavigation

    var body: some View {
        // A sidebar click can deselect the row; a pane stays selected while there is a host.
        let selection = Binding<DashboardPane?>(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })
        List(selection: selection) {
            ForEach(hosts.macs) { host in
                Section(host.name) {
                    Label("Overview", systemImage: "gauge.with.dots.needle.50percent").tag(DashboardPane.overview(host.id))
                    Label { Text("GitHub") } icon: { Image("github-mark", bundle: .module) }.tag(DashboardPane.github(host.id))
                    Label(host.name, systemImage: "desktopcomputer").tag(DashboardPane.mac(host.id))
                    ForEach(hosts.macsManaged(by: host.id).listedMacs) { mac in
                        Label(mac.name, systemImage: "desktopcomputer").tag(DashboardPane.managedMac(mac.id, host: host.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu("Add Mac…", systemImage: "plus.circle") {
                    Button("Show a Mac on This Dashboard…") { navigation.addition = .host }
                    ForEach(hosts.macs) { host in
                        Button("Add a Mac for \(host.name) to Manage…") { navigation.addition = .mac(managedBy: host.id) }
                            .disabled(!canAddMac(to: host))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pair with a Mac that runs XcodeHomeRunner to show it here, or pair one of the Macs shown here with a Mac for it to manage.")
                .accessibilityIdentifier("add-mac")
                Spacer()
            }
            .padding(10)
        }
    }

    /// Whether the host answers and can pair with another Mac. A host that another Mac manages cannot.
    private func canAddMac(to host: PairedMac) -> Bool {
        hosts.status(of: host.id) == .online && hosts.macsManaged(by: host.id).canAddMacs
    }
}

@MainActor
private struct DashboardPaneView: View {
    let hosts: PairedMacs
    let navigation: DashboardNavigation

    var body: some View {
        @Bindable var navigation = navigation
        let host = navigation.pane.flatMap { hosts.mac($0.host) }
        Group {
            if let pane = navigation.pane, let host {
                switch pane {
                case .overview:
                    DashboardHostPane(hosts: hosts, host: host) { settings, report, github in
                        HostOverviewView(
                            settings: report, github: github, mac: MacReference(name: host.name),
                            requestError: settings.githubError, actions: actions(for: host)
                        ) {
                            navigation.pane = .github(host.id)
                        }
                    }
                case .github:
                    DashboardHostPane(hosts: hosts, host: host) { settings, _, github in
                        @Bindable var settings = settings
                        GitHubSettingsView(
                            github: github, selection: $settings.selectedRepositoryIDs, mac: MacReference(name: host.name),
                            isRequesting: settings.isChangingGitHub, requestError: settings.githubError, actions: actions(for: host)
                        )
                    }
                case .mac:
                    // The host registers runners for a changed limit itself.
                    PairedMacView(macs: hosts, mac: host.listed, limitChanged: {}) {
                        navigation.pane = hosts.macs.first.map { .overview($0.id) }
                    }
                case .managedMac(let id, _):
                    let managed = hosts.macsManaged(by: host.id)
                    DashboardHostPane(hosts: hosts, host: host) { _, _, _ in
                        if let mac = managed.listedMacs.first(where: { $0.id == id }) {
                            // The host registers the Mac's runners, so it applies a changed limit to them.
                            PairedMacView(macs: managed, mac: mac, limitChanged: {}) { navigation.pane = .overview(host.id) }
                        } else {
                            ContentUnavailableView("This Mac was removed", systemImage: "desktopcomputer")
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Macs", systemImage: "desktopcomputer")
                } description: {
                    Text("Choose Add Mac… to show a Mac that runs XcodeHomeRunner. This Mac shows its status and changes its settings without running jobs itself.")
                    // A Mac's pane shows this message while one is listed. It also reports a Mac that was removed
                    // here but could not be told, and pairings that could not be read.
                    if let message = hosts.message { ErrorText(message) }
                } actions: {
                    Button("Add Mac…") { navigation.addition = .host }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title(of: navigation.pane, host: host))
        .frame(minWidth: 440, minHeight: 420)
        .sheet(item: $navigation.addition) { addition in
            switch addition {
            case .host:
                AddMacView(macs: hosts) { host in
                    navigation.addition = nil
                    navigation.pane = .overview(host.id)
                } cancel: {
                    navigation.addition = nil
                }
            case .mac(let host):
                AddMacView(macs: hosts.macsManaged(by: host)) { mac in
                    navigation.addition = nil
                    navigation.pane = .managedMac(mac.id, host: host)
                } cancel: {
                    navigation.addition = nil
                }
            }
        }
    }

    private func title(of pane: DashboardPane?, host: PairedMac?) -> String {
        guard let pane, let host else { return "XcodeHomeRunner" }
        return switch pane {
        case .overview: "Overview"
        case .github: "GitHub"
        case .mac: host.name
        case .managedMac(let id, _): hosts.macsManaged(by: host.id).listedMacs.first { $0.id == id }?.name ?? "Mac"
        }
    }

    /// The GitHub controls, which act on the host. Its pages open in this Mac's browser.
    private func actions(for host: PairedMac) -> GitHubActions {
        GitHubActions(
            signIn: { Task { await hosts.signIn(to: host.id) } },
            cancelSignIn: { Task { await hosts.cancelSignIn(to: host.id) } },
            signOut: { Task { await hosts.signOut(of: host.id) } },
            addRepositories: { hosts.addRepositories(to: host.id) },
            reloadRepositories: { Task { await hosts.reloadRepositories(of: host.id) } },
            applySelection: { Task { await hosts.applyRepositorySelection(of: host.id) } }
        )
    }
}

/// A pane that shows what a host last answered. Values from an earlier read may have changed since, so while the host
/// does not answer, the pane shows only the connection.
@MainActor
private struct DashboardHostPane<Content: View>: View {
    let hosts: PairedMacs
    let host: PairedMac
    @ViewBuilder let content: (PairedMacSettings, HostSettingsReport, GitHubReport) -> Content

    var body: some View {
        Group {
            if hosts.status(of: host.id) == .online, let settings = hosts.settings(of: host.id),
               let report = settings.report, let github = settings.github {
                content(settings, report, github)
            } else {
                Form {
                    Section {
                        PairedMacConnectionRows(macs: hosts, mac: host.listed)
                        if let message = hosts.message { ErrorText(message) }
                    }
                }
            }
        }
        .task(id: host.id) { await hosts.watchSettings(of: host.id) }
    }
}

#if DEBUG
/// The Mac that the preview host manages.
private let previewManagedMac = PairedMac(pairing: HostPairing(id: UUID(), name: "m1pro", key: Data(count: 32)), hostID: UUID())

/// A dashboard that shows the preview host, which answers over the loopback interface unless it is `notFound`.
@MainActor
private func previewDashboardSplitViewController(
    hasHost: Bool, notFound: Bool = false, pane: (HostPairing.ID) -> DashboardPane = { .overview($0) }
) -> NSSplitViewController {
    let store = PreviewSecretStore()
    let host = PairedMac(pairing: HostPairing(id: UUID(), name: "m6mini", key: Data(count: 32)), hostID: UUID())
    if hasHost { try? store.write(JSONEncoder().encode([host])) }
    let hosts = PairedMacs(store: store, name: HostPane.macName, role: .dashboard, browses: false)
    if hasHost, !notFound { connectPreviewMac(host, to: hosts, stopsAnswering: false, managing: previewManagedMac) }
    let navigation = DashboardNavigation()
    if hasHost { navigation.pane = pane(host.id) }
    return makeDashboardSplitViewController(hosts: hosts, navigation: navigation)
}

#Preview("Dashboard", traits: .fixedLayout(width: 760, height: 620)) { previewDashboardSplitViewController(hasHost: true) }
#Preview("Dashboard GitHub", traits: .fixedLayout(width: 760, height: 620)) {
    previewDashboardSplitViewController(hasHost: true, pane: { .github($0) })
}
#Preview("Dashboard Mac", traits: .fixedLayout(width: 760, height: 620)) {
    previewDashboardSplitViewController(hasHost: true, pane: { .mac($0) })
}
#Preview("Dashboard Managed Mac", traits: .fixedLayout(width: 760, height: 620)) {
    previewDashboardSplitViewController(hasHost: true, pane: { .managedMac(previewManagedMac.id, host: $0) })
}
#Preview("Dashboard Host Not Found", traits: .fixedLayout(width: 760, height: 620)) {
    previewDashboardSplitViewController(hasHost: true, notFound: true)
}
#Preview("Dashboard Without Macs", traits: .fixedLayout(width: 760, height: 620)) {
    previewDashboardSplitViewController(hasHost: false)
}
#Preview("Dashboard Add Mac", traits: .sizeThatFitsLayout) {
    AddMacView(
        macs: PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .dashboard, browses: false),
        paired: { _ in }, cancel: {}
    )
}
#endif
