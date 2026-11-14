import AppKit
import SwiftUI

/// The app opened without a host: a window that shows the hosts paired with this Mac.
///
/// It creates no runner folders or execution pool, registers no runners, and keeps only the pairings in the Keychain.
@MainActor
final class Dashboard: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let hosts: PairedMacs
    private let navigation = DashboardNavigation()
    private var windowController: NSWindowController?
    private var stopped = false

    init(hosts: PairedMacs) {
        self.hosts = hosts
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        hosts.start()
        showWindow(nil)
        print("Dashboard started.")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
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

    private func showWindow(_ sender: Any?) {
        if windowController == nil {
            windowController = makeDashboardWindowController(hosts: hosts, navigation: navigation, addMacMenu: makeAddMacMenu())
        }
        NSApplication.shared.activate()
        windowController?.showWindow(nil)
    }

    @objc private func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/lynnswap/XcodeRunnerKit/blob/main/Documentation/NativeHost.md")!)
    }

    /// The menus that people expect in the menu bar, in their usual order. Every command of the window's toolbar is
    /// here too, because a toolbar can be hidden. The menu bar host has no menu bar of its own.
    private func installMainMenu() {
        let application = NSApplication.shared
        let main = NSMenu()
        @discardableResult func add(_ menu: NSMenu) -> NSMenu {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        let app = add(NSMenu(title: "XcodeHomeRunner"))
        app.addItem(item("About XcodeHomeRunner", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        app.addItem(servicesItem)
        application.servicesMenu = services
        app.addItem(.separator())
        app.addItem(item("Hide XcodeHomeRunner", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit XcodeHomeRunner", #selector(NSApplication.terminate(_:)), "q"))

        let file = add(NSMenu(title: "File"))
        let addMac = item("Add Mac", nil)
        addMac.submenu = makeAddMacMenu()
        file.addItem(addMac)
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))

        let edit = add(NSMenu(title: "Edit"))
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        // AppKit names these two items for the current state of the sidebar and of the window.
        let view = add(NSMenu(title: "View"))
        view.addItem(item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let window = add(NSMenu(title: "Window"))
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        application.windowsMenu = window

        let help = add(NSMenu(title: "Help"))
        let guide = item("XcodeHomeRunner Help", #selector(showHelp(_:)), "?")
        guide.target = self
        help.addItem(guide)
        application.helpMenu = help

        application.mainMenu = main
    }

    /// The Add Mac menu of the toolbar and of the File menu. It lists the commands for the hosts shown when it opens.
    private func makeAddMacMenu() -> NSMenu {
        let menu = NSMenu(title: "Add Mac")
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Show a Mac on This Dashboard…", action: #selector(showMacOnDashboard(_:)), keyEquivalent: "").target = self
        for host in hosts.macs {
            let item = menu.addItem(
                withTitle: "Add a Mac for \(host.name) to Manage…", action: #selector(addManagedMac(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = host.id
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        // One sheet pairs at a time.
        case #selector(showMacOnDashboard(_:)): return navigation.addition == nil
        case #selector(addManagedMac(_:)):
            // A host has to answer, and one that another Mac manages cannot pair with a Mac.
            guard navigation.addition == nil, let host = item.representedObject as? HostPairing.ID else { return false }
            return hosts.status(of: host) == .online && hosts.macsManaged(by: host).canAddMacs
        default: return true
        }
    }

    @objc private func showMacOnDashboard(_ sender: Any?) {
        showWindow(nil)
        navigation.addition = .host
    }

    @objc private func addManagedMac(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? HostPairing.ID else { return }
        navigation.addition = .mac(managedBy: host)
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

/// Creates the dashboard window: a sidebar of paired hosts and their panes beside the selected pane, with Add Mac in
/// its toolbar.
@MainActor
func makeDashboardWindowController(hosts: PairedMacs, navigation: DashboardNavigation, addMacMenu: NSMenu) -> NSWindowController {
    makePaneWindowController(
        content: makeDashboardSplitViewController(hosts: hosts, navigation: navigation, addMacMenu: addMacMenu),
        autosaveName: "XcodeHomeRunnerDashboard"
    )
}

/// The name of a pane, which is its window's title, or of the window while no host is shown.
@MainActor
private func dashboardTitle(of pane: DashboardPane?, in hosts: PairedMacs) -> String {
    guard let pane, let host = hosts.mac(pane.host) else { return "Dashboard" }
    return switch pane {
    case .overview: "Overview"
    case .github: "GitHub"
    case .mac: host.name
    case .managedMac(let id, _): hosts.macsManaged(by: host.id).listedMacs.first { $0.id == id }?.name ?? "Mac"
    }
}

@MainActor
func makeDashboardSplitViewController(
    hosts: PairedMacs, navigation: DashboardNavigation, addMacMenu: NSMenu
) -> PaneSplitViewController {
    if navigation.pane == nil { navigation.pane = hosts.macs.first.map { .overview($0.id) } }
    let sidebar = SidebarViewController(
        groups: {
            hosts.macs.map { host in
                SidebarGroup(title: host.name, rows: [
                    SidebarRow(pane: DashboardPane.overview(host.id), title: "Overview", icon: HostPane.overview.icon),
                    SidebarRow(pane: DashboardPane.github(host.id), title: "GitHub", icon: HostPane.github.icon),
                    SidebarRow(pane: DashboardPane.mac(host.id), title: host.name, icon: HostPane.mac.icon),
                ] + hosts.macsManaged(by: host.id).listedMacs.map { mac in
                    SidebarRow(pane: DashboardPane.managedMac(mac.id, host: host.id), title: mac.name, icon: HostPane.mac.icon)
                })
            }
        },
        selection: { navigation.pane },
        // A pane stays selected while there is a host.
        select: { if let pane = $0.base as? DashboardPane { navigation.pane = pane } }
    )
    let detail = NSHostingController(rootView: DashboardPaneView(hosts: hosts, navigation: navigation))
    // The selected pane's navigation title names the window, as the host window's panes do.
    detail.sceneBridgingOptions = [.title]
    // The split view and the window decide the pane's size, also in a preview's window.
    detail.sizingOptions = []
    let split = PaneSplitViewController(
        sidebar: sidebar, detail: detail,
        addMac: .init(
            toolTip: "Pair with a Mac that runs XcodeHomeRunner to show it here, or pair one of the Macs shown here with a Mac for it to manage.",
            menu: addMacMenu
        ),
        autosaveName: "XcodeHomeRunnerDashboard"
    )
    // A window takes its first title from its content. The selected pane's navigation title names it from then on.
    split.title = dashboardTitle(of: navigation.pane, in: hosts)
    return split
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
                            // Removing one of the host's Macs returns here, where its notice stays visible.
                            notices: [settings.githubError, hosts.macsManaged(by: host.id).message].compactMap { $0 },
                            actions: actions(for: host)
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
                    PairedMacView(macs: hosts, mac: host.listed, registrationsChanged: {}) {
                        navigation.pane = hosts.macs.first.map { .overview($0.id) }
                    }
                case .managedMac(let id, _):
                    let managed = hosts.macsManaged(by: host.id)
                    DashboardHostPane(hosts: hosts, host: host) { _, _, _ in
                        if let mac = managed.listedMacs.first(where: { $0.id == id }) {
                            // The host registers the Mac's runners, so it applies a changed limit to them.
                            PairedMacView(macs: managed, mac: mac, registrationsChanged: {}) { navigation.pane = .overview(host.id) }
                        } else {
                            ContentUnavailableView("This Mac was removed", systemImage: "desktopcomputer")
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Macs", systemImage: "desktopcomputer")
                } description: {
                    Text("Add a Mac that runs XcodeHomeRunner to show it here. This Mac shows its status and changes its settings without running jobs itself.")
                    // A Mac's pane shows this message while one is listed. It also reports a Mac that was removed
                    // here but could not be told, and pairings that could not be read.
                    if let message = hosts.message { ErrorText(message) }
                } actions: {
                    Button("Add Mac…") { navigation.addition = .host }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(dashboardTitle(of: navigation.pane, in: hosts))
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
) -> PaneSplitViewController {
    let store = PreviewSecretStore()
    let host = PairedMac(pairing: HostPairing(id: UUID(), name: "m6mini", key: Data(count: 32)), hostID: UUID())
    if hasHost { try? store.write(JSONEncoder().encode([host])) }
    let hosts = PairedMacs(store: store, name: HostPane.macName, role: .dashboard, browses: false)
    if hasHost, !notFound { connectPreviewMac(host, to: hosts, stopsAnswering: false, managing: previewManagedMac) }
    let navigation = DashboardNavigation()
    if hasHost { navigation.pane = pane(host.id) }
    return makeDashboardSplitViewController(hosts: hosts, navigation: navigation, addMacMenu: NSMenu(title: "Add Mac"))
}

#Preview("Dashboard") { previewDashboardSplitViewController(hasHost: true) }
#Preview("Dashboard GitHub") {
    previewDashboardSplitViewController(hasHost: true, pane: { .github($0) })
}
#Preview("Dashboard Mac") {
    previewDashboardSplitViewController(hasHost: true, pane: { .mac($0) })
}
#Preview("Dashboard Managed Mac") {
    previewDashboardSplitViewController(hasHost: true, pane: { .managedMac(previewManagedMac.id, host: $0) })
}
#Preview("Dashboard Host Not Found") {
    previewDashboardSplitViewController(hasHost: true, notFound: true)
}
#Preview("Dashboard Without Macs") {
    previewDashboardSplitViewController(hasHost: false)
}
#Preview("Dashboard Add Mac", traits: .sizeThatFitsLayout) {
    AddMacView(
        macs: PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .dashboard, browses: false),
        paired: { _ in }, cancel: {}
    )
}
#endif
