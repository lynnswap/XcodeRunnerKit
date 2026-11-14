import AppKit
import Observation
import SwiftUI

/// The app opened without a host: a window that shows the hosts paired with this Mac.
///
/// It creates no runner folders or execution pool, registers no runners, and keeps only the pairings in the Keychain.
@MainActor
final class Dashboard: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let hosts: PairedMacs
    private var windowController: NSWindowController?
    private var content: DashboardSplitViewController? { windowController?.contentViewController as? DashboardSplitViewController }
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
            windowController = makePaneWindowController(
                content: DashboardSplitViewController(hosts: hosts, addMacMenu: makeAddMacMenu()),
                autosaveName: "XcodeHomeRunnerDashboard"
            )
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
        case #selector(showMacOnDashboard(_:)): return content?.isAddingMac != true
        case #selector(addManagedMac(_:)):
            // A host has to answer, and one that another Mac manages cannot pair with a Mac.
            guard content?.isAddingMac != true, let host = item.representedObject as? HostPairing.ID else { return false }
            return hosts.status(of: host) == .online && hosts.macsManaged(by: host).canAddMacs
        default: return true
        }
    }

    @objc private func showMacOnDashboard(_ sender: Any?) {
        showWindow(nil)
        content?.showMacOnDashboard(sender)
    }

    @objc private func addManagedMac(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? HostPairing.ID else { return }
        showWindow(nil)
        content?.addMac(managedBy: host)
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

/// What the dashboard window shows.
@MainActor @Observable
final class DashboardWindowModel {
    /// The pane that is selected in the sidebar. One stays selected while a host is shown.
    var pane: DashboardPane?
}

/// The dashboard window's content: the paired hosts and their panes in a sidebar beside the selected pane, with Add Mac
/// in the toolbar.
@MainActor
final class DashboardSplitViewController: PaneSplitViewController {
    private let hosts: PairedMacs
    private let model: DashboardWindowModel
    private let toolbarMenu: NSMenu
    /// The pane that is shown, or `nil` for the pane without a host. Nothing is shown before the view loads.
    private var shownPane: DashboardPane??

    /// - Parameter addMacMenu: The Add Mac toolbar item's choices, which the menu's delegate fills when it opens.
    init(hosts: PairedMacs, model: DashboardWindowModel = DashboardWindowModel(), addMacMenu: NSMenu) {
        self.hosts = hosts
        self.model = model
        toolbarMenu = addMacMenu
        if model.pane == nil { model.pane = hosts.macs.first.map { .overview($0.id) } }
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
            selection: { model.pane },
            select: { if let pane = $0.base as? DashboardPane { model.pane = pane } }
        )
        super.init(sidebar: sidebar, autosaveName: "XcodeHomeRunnerDashboard")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        update()
    }

    /// Shows the selected pane and names the window after it, then waits for the selection, the pane's host, or the
    /// name to change.
    private func update() {
        let (pane, title) = withObservationTracking {
            // A pane leaves with its host.
            let pane = model.pane.flatMap { hosts.mac($0.host) == nil ? nil : $0 }
            return (pane, self.title(of: pane))
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
        self.title = title
        guard pane != shownPane else { return }
        shownPane = pane
        detail.show(makeViewController(for: pane))
    }

    /// The name of a pane, or of the window while no host is shown.
    private func title(of pane: DashboardPane?) -> String {
        guard let pane, let host = hosts.mac(pane.host) else { return "Dashboard" }
        return switch pane {
        case .overview: "Overview"
        case .github: "GitHub"
        case .mac: host.name
        case .managedMac(let id, _): hosts.macsManaged(by: host.id).listedMacs.first { $0.id == id }?.name ?? "Mac"
        }
    }

    private func makeViewController(for pane: DashboardPane?) -> NSViewController {
        guard let pane, let host = hosts.mac(pane.host) else {
            return NoMacsViewController(hosts: hosts) { [weak self] in self?.showMacOnDashboard(nil) }
        }
        switch pane {
        case .overview:
            return OverviewViewController(model: OverviewModel(hosts: hosts, host: host) { [model] in model.pane = .github(host.id) })
        case .github: return GitHubViewController(model: GitHubPaneModel(hosts: hosts, host: host))
        case .mac:
            // The host registers runners for a changed limit itself.
            return MacViewController(model: MacPaneModel(macs: hosts, id: host.id) { [hosts, model] in
                model.pane = hosts.macs.first.map { .overview($0.id) }
            })
        case .managedMac(let id, _):
            // The host registers the Mac's runners, so it applies a changed limit to them.
            return MacViewController(model: MacPaneModel(
                macs: hosts.macsManaged(by: host.id), id: id, relay: (hosts, host.id),
                removed: { [model] in model.pane = .overview(host.id) }
            ))
        }
    }

    override var addMacToolTip: String {
        "Pair with a Mac that runs XcodeHomeRunner to show it here, or pair one of the Macs shown here with a Mac for it to manage."
    }

    override var addMacMenu: NSMenu? { toolbarMenu }

    /// Pairs this dashboard with a Mac that runs a host, and shows that host.
    @objc func showMacOnDashboard(_ sender: Any?) {
        guard !isAddingMac else { return }
        presentAddMacSheet(for: hosts) { [model] host in model.pane = .overview(host.id) }
    }

    /// Pairs a host with a Mac for it to manage, and shows that Mac.
    func addMac(managedBy host: HostPairing.ID) {
        guard !isAddingMac else { return }
        presentAddMacSheet(for: hosts.macsManaged(by: host)) { [model] mac in model.pane = .managedMac(mac.id, host: host) }
    }
}

/// The dashboard's pane while it shows no host.
@MainActor
final class NoMacsViewController: NSHostingController<NoMacsView> {
    /// - Parameter addMac: Pairs the dashboard with a Mac that runs a host.
    init(hosts: PairedMacs, addMac: @escaping @MainActor () -> Void) {
        super.init(rootView: NoMacsView(hosts: hosts, addMac: addMac))
        sizingOptions = []
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
struct NoMacsView: View {
    let hosts: PairedMacs
    let addMac: @MainActor () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Macs", systemImage: "desktopcomputer")
        } description: {
            Text("Add a Mac that runs XcodeHomeRunner to show it here. This Mac shows its status and changes its settings without running jobs itself.")
            // A Mac's pane shows this message while one is listed. It also reports a Mac that was removed here but
            // could not be told, and pairings that could not be read.
            if let message = hosts.message { ErrorText(message) }
        } actions: {
            Button("Add Mac…", action: addMac)
        }
    }
}

#if DEBUG
/// The Mac that the preview host manages.
private let previewManagedMac = PairedMac(pairing: HostPairing(id: UUID(), name: "m1pro", key: Data(count: 32)), hostID: UUID())

/// A dashboard that shows the preview host, which answers over the loopback interface unless it is `notFound`.
@MainActor
private func previewDashboardSplitViewController(
    hasHost: Bool, notFound: Bool = false, pane: (HostPairing.ID) -> DashboardPane = { .overview($0) }
) -> DashboardSplitViewController {
    let store = PreviewSecretStore()
    let host = PairedMac(pairing: HostPairing(id: UUID(), name: "m6mini", key: Data(count: 32)), hostID: UUID())
    if hasHost { try? store.write(JSONEncoder().encode([host])) }
    let hosts = PairedMacs(store: store, name: HostPane.macName, role: .dashboard, browses: false)
    if hasHost, !notFound { connectPreviewMac(host, to: hosts, stopsAnswering: false, managing: previewManagedMac) }
    let model = DashboardWindowModel()
    if hasHost { model.pane = pane(host.id) }
    return DashboardSplitViewController(hosts: hosts, model: model, addMacMenu: NSMenu(title: "Add Mac"))
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
#endif
