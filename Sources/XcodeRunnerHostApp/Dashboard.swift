import AppKit
import Observation
import SwiftUI

/// The app opened without a host: a menu bar item and a window that show the hosts paired with this Mac.
///
/// It creates no runner folders or execution pool, registers no runners, and keeps only the pairings in the Keychain.
/// It stays in the menu bar after its window closes, and is in the Dock only while the window is open.
@MainActor
final class Dashboard: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let hosts: PairedMacs
    private var windowController: NSWindowController?
    private var content: DashboardSplitViewController? { windowController?.contentViewController as? DashboardSplitViewController }
    private var statusItem: NSStatusItem?
    /// The menu bar item's menu. It lists the hosts as they are when it opens.
    let statusMenu = NSMenu()
    private var stopped = false

    init(hosts: PairedMacs) {
        self.hosts = hosts
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installStatusItem()
        hosts.start()
        showWindow(nil)
        print("Dashboard started.")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
                content: DashboardSplitViewController(model: DashboardWindowModel(hosts: hosts)),
                autosaveName: "XcodeHomeRunnerDashboard"
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification,
                object: windowController?.window
            )
        }
        // The window's menus are in the menu bar only for an app that is in the Dock.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        windowController?.showWindow(nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "hammer.circle", accessibilityDescription: "XcodeHomeRunner")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "XcodeHomeRunner"
        statusMenu.delegate = self
        item.menu = statusMenu
        statusItem = item
    }

    /// Lists each host with its state and jobs, as its Overview shows them, above the commands.
    private func updateStatusMenu() {
        statusMenu.removeAllItems()
        for host in hosts.macs {
            let item = statusMenu.addItem(withTitle: host.name, action: #selector(showHost(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = host.id
            let connection = hosts.status(of: host.id)
            // What the host last answered names its state, and its connection does while it does not answer.
            if let report = hosts.answer(of: host.id)?.report {
                item.subtitle = "\(report.stateTitle) · \(report.jobSummary)"
                item.image = NSImage(systemSymbolName: report.stateSymbol, accessibilityDescription: report.stateTitle)?
                    .withSymbolConfiguration(.init(paletteColors: [report.stateTint]))
            } else {
                item.subtitle = connection.title
                item.image = NSImage(systemSymbolName: connection.systemImage, accessibilityDescription: connection.title)?
                    .withSymbolConfiguration(.init(paletteColors: [connection.tint]))
            }
        }
        if hosts.macs.isEmpty {
            statusMenu.addItem(withTitle: "No Macs", action: nil, keyEquivalent: "")
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Open Dashboard", action: #selector(showDashboard(_:)), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: "Quit XcodeHomeRunner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ).target = NSApplication.shared
    }

    @objc private func showDashboard(_ sender: Any?) {
        showWindow(nil)
    }

    /// Opens the window on the Overview of the host that the person chose in the menu bar item's menu.
    @objc private func showHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? HostPairing.ID else { return }
        showWindow(nil)
        content?.show(.overview(host))
    }

    @objc private func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/lynnswap/XcodeRunnerKit/blob/main/Documentation/NativeHost.md")!)
    }

    /// The menus that people expect in the menu bar, in their usual order, with the commands that pair with Macs. The
    /// menu bar host has no menu bar of its own.
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

    /// The File menu's Add Mac menu. It lists the commands for the hosts shown when it opens.
    private func makeAddMacMenu() -> NSMenu {
        let menu = NSMenu(title: "Add Mac")
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu !== statusMenu else { return updateStatusMenu() }
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

/// What the dashboard window shows: the paired hosts and their panes in the sidebar, and the selected pane.
@MainActor @Observable
final class DashboardWindowModel: PaneWindowModel {
    let hosts: PairedMacs
    /// The pane that the person selected. One stays selected while a host is shown.
    var pane: DashboardPane?

    /// - Parameter pane: The pane to show first, or `nil` for the first host's Overview.
    init(hosts: PairedMacs, pane: DashboardPane? = nil) {
        self.hosts = hosts
        self.pane = pane ?? hosts.macs.first.map { .overview($0.id) }
    }

    /// The selected pane, while the dashboard still shows its host. A pane leaves with its host.
    var shownPane: DashboardPane? { pane.flatMap { hosts.mac($0.host) == nil ? nil : $0 } }

    var sidebarGroups: [SidebarGroup] {
        hosts.macs.map { host in
            // What the host last answered names its state, and its connection does while it does not answer.
            let answer = hosts.answer(of: host.id)
            let connection = hosts.status(of: host.id)
            let managed = hosts.macsManaged(by: host.id)
            return SidebarGroup(title: host.name, rows: [
                SidebarRow(
                    pane: DashboardPane.overview(host.id), title: "Overview", subtitle: answer?.report.stateTitle ?? connection.title,
                    icon: HostPane.overview.icon,
                    status: answer.map { .init(symbol: $0.report.stateSymbol, color: $0.report.stateTint) }
                        ?? .init(symbol: connection.systemImage, color: connection.tint)
                ),
                SidebarRow(
                    pane: DashboardPane.github(host.id), title: "GitHub",
                    subtitle: answer.map { $0.github.accountLogin ?? "Not connected" }, icon: HostPane.github.icon
                ),
                SidebarRow(
                    pane: DashboardPane.mac(host.id), title: host.name, subtitle: answer?.report.runnerCountTitle, icon: HostPane.mac.icon
                ),
            ] + managed.listedMacs.map { mac in
                // The host's list of Macs is as old as its last answer, so their states are not shown without one.
                let status = answer == nil ? nil : managed.status(of: mac.id)
                return SidebarRow(
                    pane: DashboardPane.managedMac(mac.id, host: host.id), title: mac.name, subtitle: status?.title,
                    icon: HostPane.mac.icon, status: status.map { .init(symbol: $0.systemImage, color: $0.tint) }
                )
            })
        }
    }

    var selectedPane: AnyHashable? { shownPane }

    func select(_ pane: AnyHashable) {
        if let pane = pane.base as? DashboardPane { self.pane = pane }
    }

    /// The name of the shown pane, or of the window while no host is shown.
    var title: String {
        guard let pane = shownPane, let host = hosts.mac(pane.host) else { return "Dashboard" }
        return switch pane {
        case .overview: "Overview"
        case .github: "GitHub"
        case .mac: host.name
        case .managedMac(let id, _): hosts.macsManaged(by: host.id).listedMacs.first { $0.id == id }?.name ?? "Mac"
        }
    }
}

/// The dashboard window's content: the paired hosts and their panes in a sidebar beside the selected pane.
@MainActor
final class DashboardSplitViewController: PaneSplitViewController {
    private let model: DashboardWindowModel
    private var hosts: PairedMacs { model.hosts }

    init(model: DashboardWindowModel) {
        self.model = model
        super.init(model: model, autosaveName: "XcodeHomeRunnerDashboard")
    }

    required init?(coder: NSCoder) { nil }

    override func makePaneViewController() -> NSViewController {
        guard let pane = model.shownPane, let host = hosts.mac(pane.host) else {
            return NoMacsViewController(hosts: hosts) { [weak self] in self?.showMacOnDashboard(nil) }
        }
        switch pane {
        case .overview:
            return OverviewViewController(model: OverviewModel(
                hosts: hosts, host: host, showGitHub: { [model] in model.pane = .github(host.id) },
                addMac: { [weak self] in self?.addMac(managedBy: host.id) }
            ))
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

    /// Shows a pane of a host that the dashboard lists.
    func show(_ pane: DashboardPane) {
        model.pane = pane
    }

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
#Preview("Dashboard") { HostPreview.dashboard(hasHost: true) }
#Preview("Dashboard GitHub") {
    HostPreview.dashboard(hasHost: true, pane: { .github($0) })
}
#Preview("Dashboard Mac") {
    HostPreview.dashboard(hasHost: true, pane: { .mac($0) })
}
#Preview("Dashboard Managed Mac") {
    HostPreview.dashboard(hasHost: true, pane: { .managedMac(HostPreview.hostManagedMac.id, host: $0) })
}
#Preview("Dashboard Host Not Found") {
    HostPreview.dashboard(hasHost: true, notFound: true)
}
#Preview("Dashboard Without Macs") {
    HostPreview.dashboard(hasHost: false)
}
#endif
