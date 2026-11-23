import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// The app opened without a host: a menu bar item and a window that show the host paired with this Mac.
///
/// It creates no runner folders or execution pool, registers no runners, and keeps only its pairing in the Keychain.
/// It stays in the menu bar after its window closes, and is in the Dock only while the window is open.
@MainActor
final class Dashboard: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let pairing: PairedMacs
    private var windowController: NSWindowController?
    private var settingsWindow: NSWindow?
    private lazy var openAtLogin = NSButton(
        checkboxWithTitle: "Open dashboard at login", target: self, action: #selector(changeOpenAtLogin(_:))
    )
    private var content: DashboardSplitViewController? { windowController?.contentViewController as? DashboardSplitViewController }
    private var statusItem: NSStatusItem?
    /// Shows the most recent status when the menu opens.
    let statusMenu = NSMenu()
    private var hostReading: Task<Void, Never>?
    private var stopped = false

    init(pairing: PairedMacs) {
        self.pairing = pairing
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpLoginItem()
        installMainMenu()
        installStatusItem()
        pairing.start()
        // A CLI command can change the pairing in a separate process.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(hostChangedByCommand(_:)), name: HostControl.dashboardHostChangedNotification,
            object: nil
        )
        hostReading = Task {
            while true {
                if let host = pairing.dashboardHost { await pairing.refresh(host.id) }
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
            await pairing.shutDown()
            stopped = true
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func showWindow(_ sender: Any?) {
        if windowController == nil {
            windowController = makePaneWindowController(
                content: DashboardSplitViewController(model: DashboardWindowModel(pairing: pairing)),
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

    @objc private func hostChangedByCommand(_ notification: Notification) {
        pairing.reload()
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
    static func retireLoginItemForHost() {
        guard UserDefaults.standard.bool(forKey: didSetUpLoginItem) else { return }
        let service = SMAppService.mainApp
        let status = service.status
        guard status == .enabled || status == .requiresApproval else { return }
        do { try service.unregister() } catch {
            NSLog("Could not remove the dashboard login item: %@", error.localizedDescription)
        }
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

    private func updateStatusMenu() {
        statusMenu.removeAllItems()
        if let host = pairing.dashboardHost {
            let item = statusMenu.addItem(withTitle: host.name, action: #selector(showHost(_:)), keyEquivalent: "")
            item.target = self
            if let report = pairing.answer(of: host.id)?.report {
                item.subtitle = "\(report.stateTitle) · \(report.jobSummary)"
                item.image = NSImage(systemSymbolName: report.stateSymbol, accessibilityDescription: report.stateTitle)?
                    .withSymbolConfiguration(.init(paletteColors: [report.stateTint]))
            } else {
                let connection = pairing.status(of: host.id)
                item.subtitle = connection.title
                item.image = NSImage(systemSymbolName: connection.systemImage, accessibilityDescription: connection.title)?
                    .withSymbolConfiguration(.init(paletteColors: [connection.tint]))
            }
        } else {
            statusMenu.addItem(withTitle: "Open Dashboard…", action: #selector(showHost(_:)), keyEquivalent: "").target = self
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: "Quit XcodeHomeRunner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ).target = NSApplication.shared
    }

    @objc private func showHost(_ sender: Any?) {
        showWindow(nil)
        content?.showOverview()
    }

    @objc private func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/lynnswap/XcodeHomeRunner/blob/main/Documentation/NativeHost.md")!)
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

    /// Rebuild the Add Mac menu for the current pairing when it opens.
    private func makeAddMacMenu() -> NSMenu {
        let menu = NSMenu(title: "Add Mac")
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu !== statusMenu else { return updateStatusMenu() }
        menu.removeAllItems()
        if pairing.dashboardHost != nil {
            menu.addItem(withTitle: "Add Runner Mac…", action: #selector(addManagedMac(_:)), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Pair Host…", action: #selector(showMacOnDashboard(_:)), keyEquivalent: "").target = self
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showMacOnDashboard(_:)): return content?.isAddingMac != true && pairing.macs.isEmpty
        case #selector(addManagedMac(_:)):
            guard content?.isAddingMac != true, let host = pairing.dashboardHost else { return false }
            return pairing.status(of: host.id) == .online && pairing.macsManaged(by: host.id).canAddMacs
        default: return true
        }
    }

    @objc private func showMacOnDashboard(_ sender: Any?) {
        showWindow(nil)
        content?.showMacOnDashboard(sender)
    }

    @objc private func addManagedMac(_ sender: Any?) {
        showWindow(nil)
        content?.addRunner()
    }
}

/// The host ID invalidates the displayed controller when a command changes the pairing.
private struct DashboardPane: Hashable {
    let host: HostPairing.ID
    let pane: HostPane
}

@MainActor @Observable
final class DashboardWindowModel: PaneWindowModel {
    let pairing: PairedMacs
    var pane: HostPane

    init(pairing: PairedMacs, pane: HostPane = .overview) {
        self.pairing = pairing
        self.pane = pane
    }

    var shownPane: HostPane {
        if case .managedMac(let id) = pane, let host = pairing.dashboardHost,
           !pairing.macsManaged(by: host.id).listedMacs.contains(where: { $0.id == id }) { return .overview }
        return pane
    }

    var sidebarGroups: [SidebarGroup] {
        guard let host = pairing.dashboardHost else { return [] }
        let answer = pairing.answer(of: host.id)
        let connection = pairing.status(of: host.id)
        let managed = pairing.macsManaged(by: host.id)
        return [
            SidebarGroup(title: nil, rows: [
                SidebarRow(
                    pane: DashboardPane(host: host.id, pane: .overview), title: "Settings",
                    subtitle: answer?.report.stateTitle ?? connection.title, icon: HostPane.overview.icon,
                    status: answer.map { .init(symbol: $0.report.stateSymbol, color: $0.report.stateTint) }
                        ?? .init(symbol: connection.systemImage, color: connection.tint)
                ),
            ]),
            SidebarGroup(title: "Runners", rows: [
                SidebarRow(pane: DashboardPane(host: host.id, pane: .mac), title: host.name,
                           subtitle: answer?.report.runnerActivityTitle ?? connection.title, icon: HostPane.mac.icon),
            ] + managed.listedMacs.map { mac in
                let status = answer == nil ? nil : managed.status(of: mac.id)
                return SidebarRow(
                    pane: DashboardPane(host: host.id, pane: .managedMac(mac.id)), title: mac.name,
                    subtitle: answer == nil ? connection.title : managed.runnerActivityTitle(of: mac), icon: HostPane.mac.icon,
                    status: status.map { .init(symbol: $0.systemImage, color: $0.tint) }
                )
            }),
        ]
    }

    var selectedPane: AnyHashable? { pairing.dashboardHost.map { AnyHashable(DashboardPane(host: $0.id, pane: shownPane)) } }

    func select(_ row: AnyHashable) {
        if let selection = row.base as? DashboardPane { pane = selection.pane }
    }

    var title: String {
        guard let host = pairing.dashboardHost else { return "Dashboard" }
        return switch shownPane {
        case .overview: "Settings"
        case .mac: host.name
        case .managedMac(let id): pairing.macsManaged(by: host.id).listedMacs.first { $0.id == id }?.name ?? "Mac"
        }
    }
}

@MainActor
final class DashboardSplitViewController: PaneSplitViewController {
    private let model: DashboardWindowModel
    private var pairing: PairedMacs { model.pairing }
    private let canPairHost: @MainActor () -> Bool

    init(model: DashboardWindowModel, canPairHost: @escaping @MainActor () -> Bool = { true }) {
        self.model = model
        self.canPairHost = canPairHost
        super.init(model: model, autosaveName: "XcodeHomeRunnerDashboard")
    }

    required init?(coder: NSCoder) { nil }

    override func makePaneViewController() -> NSViewController {
        guard let host = pairing.dashboardHost else {
            return NoMacsViewController(pairing: pairing, canPairHost: canPairHost) { [weak self] in self?.showMacOnDashboard(nil) }
        }
        switch model.shownPane {
        case .overview:
            return OverviewViewController(model: OverviewModel(hosts: pairing, host: host) { [weak self] in self?.addRunner() })
        case .mac:
            return MacViewController(model: MacPaneModel(macs: pairing, id: host.id, removed: { [model] in model.pane = .overview }))
        case .managedMac(let id):
            return MacViewController(model: MacPaneModel(
                macs: pairing.macsManaged(by: host.id), id: id, relay: (pairing, host.id), removed: { [model] in model.pane = .overview }
            ))
        }
    }

    func showOverview() { model.pane = .overview }

    @objc func showMacOnDashboard(_ sender: Any?) {
        guard canPairHost(), !isAddingMac, pairing.macs.isEmpty else { return }
        presentAddMacSheet(for: pairing) { [model] _ in model.pane = .overview }
    }

    func addRunner() {
        guard !isAddingMac, let host = pairing.dashboardHost else { return }
        presentAddMacSheet(for: pairing.macsManaged(by: host.id)) { [model] mac in model.pane = .managedMac(mac.id) }
    }
}

/// The dashboard's pane while it shows no host.
@MainActor
final class NoMacsViewController: NSHostingController<NoMacsView> {
    /// - Parameter addMac: Pairs the dashboard with a Mac that runs a host.
    init(pairing: PairedMacs, canPairHost: @escaping @MainActor () -> Bool, addMac: @escaping @MainActor () -> Void) {
        super.init(rootView: NoMacsView(pairing: pairing, canPairHost: canPairHost, addMac: addMac))
        sizingOptions = []
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
struct NoMacsView: View {
    let pairing: PairedMacs
    let canPairHost: @MainActor () -> Bool
    let addMac: @MainActor () -> Void

    @State private var confirming: PairedMac?

    var body: some View {
        ContentUnavailableView {
            Label(pairing.hasLegacyHosts ? "Choose Your Host" : "No Paired Host", systemImage: "desktopcomputer")
        } description: {
            if let recovery = pairing.legacyHostMessage { Text(recovery) }
            else if canPairHost() { Text("Pair this dashboard with the Mac that hosts your runners.") }
            else { Text("Open Settings to manage the runners on this host.") }
            if let message = pairing.message { ErrorText(message) }
        } actions: {
            if pairing.hasLegacyHosts {
                Menu("Disconnect Host…") {
                    ForEach(pairing.macs) { mac in
                        Button("\(mac.name) (\(mac.id.uuidString))") { confirming = mac }
                    }
                }
                .disabled(pairing.isDisconnectingLegacyHost)
                .confirmationDialog("Disconnect \(confirming?.name ?? "Host")?", isPresented: Binding(
                    get: { confirming != nil }, set: { if !$0 { confirming = nil } }
                ), presenting: confirming) { mac in
                    Button("Disconnect", role: .destructive) { Task { await pairing.remove(mac.id) } }
                } message: { _ in
                    Text("To connect to this host again, you will need to pair the Macs again.")
                }
            } else if canPairHost(), pairing.macs.isEmpty {
                Button("Pair Host…", action: addMac)
            }
        }
    }
}

#if DEBUG
#Preview("Dashboard") { HostPreview.dashboard(hasHost: true) }
#Preview("Dashboard Mac") {
    HostPreview.dashboard(hasHost: true, pane: .mac)
}
#Preview("Dashboard Managed Mac") {
    HostPreview.dashboard(hasHost: true, pane: .managedMac(HostPreview.hostManagedMac.id))
}
#Preview("Dashboard Host Not Found") {
    HostPreview.dashboard(hasHost: true, notFound: true)
}
#Preview("Dashboard Without Macs") {
    HostPreview.dashboard(hasHost: false)
}
#endif
