import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// The app opened without a host: a menu bar item and a window that show the hosts paired with this Mac.
///
/// It creates no runner folders or execution pool, registers no runners, and keeps only the pairings in the Keychain.
/// It stays in the menu bar after its window closes, and is in the Dock only while the window is open.
@MainActor
final class Dashboard: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let hosts: PairedMacs
    private var windowController: NSWindowController?
    private var settingsWindow: NSWindow?
    private lazy var openAtLogin = NSButton(
        checkboxWithTitle: "Open dashboard at login", target: self, action: #selector(changeOpenAtLogin(_:))
    )
    private var content: DashboardSplitViewController? { windowController?.contentViewController as? DashboardSplitViewController }
    private var statusItem: NSStatusItem?
    /// The menu bar item's menu. It lists the hosts as they were last read when it opens.
    let statusMenu = NSMenu()
    /// Reads the hosts every few seconds while the dashboard runs, so that the menu shows their current jobs. The
    /// main actor does not run while a menu is open, so the hosts cannot be read then, and they are otherwise read
    /// once a minute.
    private var hostReading: Task<Void, Never>?
    /// The hosts whose read has not ended. A host that does not answer is not read again before its request times
    /// out, and does not keep the others waiting.
    private var hostsBeingRead: Set<HostPairing.ID> = []
    private var stopped = false

    init(hosts: PairedMacs) {
        self.hosts = hosts
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpLoginItem()
        installMainMenu()
        installStatusItem()
        hosts.start()
        // A command pairs and removes hosts in its own process, and saves them where this dashboard reads them.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(hostsChangedByCommand(_:)), name: HostControl.dashboardHostsChangedNotification,
            object: nil
        )
        hostReading = Task {
            while true {
                for host in hosts.macs where hostsBeingRead.insert(host.id).inserted {
                    Task {
                        await hosts.refresh(host.id)
                        hostsBeingRead.remove(host.id)
                    }
                }
                do { try await Task.sleep(for: PairedMacs.settingsInterval) } catch { return }
            }
        }
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
        hostReading?.cancel()
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

    @objc private func hostsChangedByCommand(_ notification: Notification) {
        hosts.reload()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        let windows = [windowController?.window, settingsWindow].compactMap { $0 }
        let closing = notification.object as? NSWindow
        if !windows.contains(where: { $0 !== closing && $0.isVisible }) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    // macOS uses notRegistered both on first launch and after the person removes the login item.
    private static let didSetUpLoginItem = "didSetUpDashboardLoginItem"

    /// A Mac promoted to a host starts from its LaunchAgent. An old dashboard login item can still open this copy.
    @discardableResult
    static func retireLoginItemForHost() -> Bool {
        guard UserDefaults.standard.bool(forKey: didSetUpLoginItem) else { return false }
        let service = SMAppService.mainApp
        let status = service.status
        guard status == .enabled || status == .requiresApproval else { return false }
        do { try service.unregister() } catch {
            NSLog("Could not remove the dashboard login item: %@", error.localizedDescription)
        }
        return status == .enabled
    }

    private func setUpLoginItem() {
        guard !UserDefaults.standard.bool(forKey: Self.didSetUpLoginItem) else { return }
        do {
            try registerLoginItemIfNeeded()
            UserDefaults.standard.set(true, forKey: Self.didSetUpLoginItem)
        } catch {
            NSLog("Could not register the dashboard to open at login: %@", error.localizedDescription)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if settingsWindow?.isVisible == true { refreshLoginItem() }
    }

    private func refreshLoginItem() {
        openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func registerLoginItemIfNeeded() throws {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: break
        default: try SMAppService.mainApp.register()
        }
    }

    @objc private func changeOpenAtLogin(_ sender: NSButton) {
        let service = SMAppService.mainApp
        do {
            if sender.state == .on {
                try registerLoginItemIfNeeded()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
            UserDefaults.standard.set(true, forKey: Self.didSetUpLoginItem)
        } catch {
            NSApp.presentError(error)
        }
        refreshLoginItem()
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let stack = NSStackView(views: [openAtLogin])
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: stack.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Dashboard Settings"
            window.contentView = stack
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window
            )
        }
        refreshLoginItem()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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

    /// Lists each host above the commands.
    private func updateStatusMenu() {
        statusMenu.removeAllItems()
        for host in hosts.macs {
            let item = statusMenu.addItem(withTitle: host.name, action: #selector(showHost(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = host.id
        }
        if hosts.macs.isEmpty {
            statusMenu.addItem(withTitle: "Add Mac…", action: #selector(showMacOnDashboard(_:)), keyEquivalent: "").target = self
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: "Quit XcodeHomeRunner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ).target = NSApplication.shared
        showHostStates()
    }

    /// Shows each listed host's state and jobs on its item.
    private func showHostStates() {
        for item in statusMenu.items {
            guard let host = item.representedObject as? HostPairing.ID else { continue }
            // What the host last answered names its state, and its connection does while it does not answer.
            if let report = hosts.answer(of: host)?.report {
                item.subtitle = "\(report.stateTitle) · \(report.jobSummary)"
                item.image = NSImage(systemSymbolName: report.stateSymbol, accessibilityDescription: report.stateTitle)?
                    .withSymbolConfiguration(.init(paletteColors: [report.stateTint]))
            } else {
                let connection = hosts.status(of: host)
                item.subtitle = connection.title
                item.image = NSImage(systemSymbolName: connection.systemImage, accessibilityDescription: connection.title)?
                    .withSymbolConfiguration(.init(paletteColors: [connection.tint]))
            }
        }
    }

    /// Opens the window on the settings of the host that the person chose in the menu bar item's menu.
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
        let settings = item("Settings…", #selector(showSettings(_:)), ",")
        settings.target = self
        app.addItem(settings)
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
        file.addItem(item("Save", #selector(PaneSplitViewController.savePane(_:)), "s"))
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
    /// The host's role, status, GitHub sign-in, repositories, and pairings.
    case overview(HostPairing.ID)
    /// The host's runner services and execution settings.
    case mac(HostPairing.ID)
    /// A Mac that the host manages, which the dashboard reaches through the host.
    case managedMac(HostPairing.ID, host: HostPairing.ID)

    var host: HostPairing.ID {
        switch self {
        case .overview(let host), .mac(let host), .managedMac(_, let host): host
        }
    }
}

/// What the dashboard window shows: the paired hosts and their panes in the sidebar, and the selected pane.
@MainActor @Observable
final class DashboardWindowModel: PaneWindowModel {
    let hosts: PairedMacs
    /// The pane that the person selected. One stays selected while a host is shown.
    var pane: DashboardPane?

    /// - Parameter pane: The pane to show first, or `nil` for the first host's Settings.
    init(hosts: PairedMacs, pane: DashboardPane? = nil) {
        self.hosts = hosts
        self.pane = pane ?? hosts.macs.first.map { .overview($0.id) }
    }

    /// The selected pane, while the dashboard still shows its host. A pane leaves with its host.
    var shownPane: DashboardPane? { pane.flatMap { hosts.mac($0.host) == nil ? nil : $0 } }

    /// A host's settings are those of everything that it manages, and the Macs that run its jobs follow under
    /// Runners, the host among them, as in the host's own window. Several hosts are told apart by their names.
    var sidebarGroups: [SidebarGroup] { Self.sidebarGroups(of: hosts, namingHosts: hosts.macs.count > 1) }

    /// - Parameter namesHosts: Whether the headings name each host, which tells its panes from another Mac's.
    static func sidebarGroups(of hosts: PairedMacs, namingHosts namesHosts: Bool) -> [SidebarGroup] {
        hosts.macs.flatMap { host in
            // What the host last answered names its state, and its connection does while it does not answer.
            let answer = hosts.answer(of: host.id)
            let connection = hosts.status(of: host.id)
            let managed = hosts.macsManaged(by: host.id)
            return [
                SidebarGroup(title: namesHosts ? host.name : nil, rows: [
                    SidebarRow(
                        pane: DashboardPane.overview(host.id), title: "Settings",
                        subtitle: answer?.report.stateTitle ?? connection.title, icon: HostPane.overview.icon,
                        status: answer.map { .init(symbol: $0.report.stateSymbol, color: $0.report.stateTint) }
                            ?? .init(symbol: connection.systemImage, color: connection.tint)
                    ),
                ]),
                SidebarGroup(title: namesHosts ? "\(host.name) Runners" : "Runners", rows: [
                    SidebarRow(
                        pane: DashboardPane.mac(host.id), title: host.name, subtitle: answer?.report.runnerActivityTitle ?? connection.title,
                        icon: HostPane.mac.icon
                    ),
                ] + managed.listedMacs.map { mac in
                    // The host's list of Macs is as old as its last answer, so their states are not shown without one.
                    let status = answer == nil ? nil : managed.status(of: mac.id)
                    return SidebarRow(
                        pane: DashboardPane.managedMac(mac.id, host: host.id), title: mac.name, subtitle: answer == nil ? connection.title : managed.runnerActivityTitle(of: mac),
                        icon: HostPane.mac.icon, status: status.map { .init(symbol: $0.systemImage, color: $0.tint) }
                    )
                }),
            ]
        }
    }

    var selectedPane: AnyHashable? { shownPane }

    func select(_ pane: AnyHashable) {
        if let pane = pane.base as? DashboardPane { self.pane = pane }
    }

    /// The name of the shown pane, or of the window while no host is shown.
    var title: String { shownPane.flatMap { Self.title(of: $0, in: hosts) } ?? "Dashboard" }

    /// The name of a pane, or `nil` for a pane whose host left the list.
    static func title(of pane: DashboardPane, in hosts: PairedMacs) -> String? {
        guard let host = hosts.mac(pane.host) else { return nil }
        return switch pane {
        case .overview: "Settings"
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
        return makeDashboardPaneViewController(
            pane, of: host, in: hosts, addMac: { [weak self] in self?.addMac(managedBy: host.id) },
            show: { [model] in model.pane = $0 }
        )
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

/// Creates a pane of a host that a window shows as a dashboard.
///
/// - Parameters:
///   - addMac: Pairs the host with a Mac for it to manage.
///   - show: Shows another of the hosts' panes after the pane's Mac was removed, or `nil` when no host is left.
@MainActor
func makeDashboardPaneViewController(
    _ pane: DashboardPane, of host: PairedMac, in hosts: PairedMacs, addMac: @escaping @MainActor () -> Void,
    show: @escaping @MainActor (DashboardPane?) -> Void
) -> NSViewController {
    switch pane {
    case .overview:
        OverviewViewController(model: OverviewModel(hosts: hosts, host: host, addMac: addMac))
    case .mac:
        // The host registers runners for a changed limit itself.
        MacViewController(model: MacPaneModel(macs: hosts, id: host.id) { [hosts] in
            show(hosts.macs.first.map { .overview($0.id) })
        })
    case .managedMac(let id, _):
        // The host registers the Mac's runners, so it applies a changed limit to them.
        MacViewController(model: MacPaneModel(
            macs: hosts.macsManaged(by: host.id), id: id, relay: (hosts, host.id), removed: { show(.overview(host.id)) }
        ))
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
