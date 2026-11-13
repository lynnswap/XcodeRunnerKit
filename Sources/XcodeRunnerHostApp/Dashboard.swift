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

@MainActor @Observable
final class DashboardNavigation {
    var host: HostPairing.ID?
    var isAddingMac = false
}

/// Creates the dashboard window: a sidebar of paired hosts beside the selected host's pane.
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
    if navigation.host == nil { navigation.host = hosts.macs.first?.id }
    let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: DashboardSidebar(hosts: hosts, navigation: navigation)))
    sidebar.canCollapse = false
    sidebar.minimumThickness = 180
    let detail = NSHostingController(rootView: DashboardHostView(hosts: hosts, navigation: navigation))
    // The selected host's navigation title names the window, as the host window's panes do.
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
        // A sidebar click can deselect the row; a host stays selected while there is one.
        let selection = Binding<HostPairing.ID?>(get: { navigation.host }, set: { if let host = $0 { navigation.host = host } })
        List(selection: selection) {
            Section("Macs") {
                ForEach(hosts.macs) { mac in
                    Label(mac.name, systemImage: "desktopcomputer").tag(mac.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add Mac…", systemImage: "plus.circle") { navigation.isAddingMac = true }
                    .buttonStyle(.borderless)
                    .help("Pair with a Mac that runs XcodeHomeRunner on the local network to show it here.")
                    .accessibilityIdentifier("add-mac")
                Spacer()
            }
            .padding(10)
        }
    }
}

@MainActor
private struct DashboardHostView: View {
    let hosts: PairedMacs
    let navigation: DashboardNavigation

    var body: some View {
        @Bindable var navigation = navigation
        let host = navigation.host.flatMap { hosts.mac($0) }
        Group {
            if let host {
                // The host registers runners for a changed limit itself.
                PairedMacView(macs: hosts, mac: host, limitChanged: {}, removed: { navigation.host = hosts.macs.first?.id })
            } else {
                ContentUnavailableView {
                    Label("No Macs", systemImage: "desktopcomputer")
                } description: {
                    Text("Choose Add Mac… to show a Mac that runs XcodeHomeRunner. This Mac shows its status and changes its settings without running jobs itself.")
                    // A Mac's pane shows this message while one is listed. It also reports a Mac that was removed
                    // here but could not be told, and pairings that could not be read.
                    if let message = hosts.message { ErrorText(message) }
                } actions: {
                    Button("Add Mac…") { navigation.isAddingMac = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(host?.name ?? "XcodeHomeRunner")
        .frame(minWidth: 440, minHeight: 420)
        .sheet(isPresented: $navigation.isAddingMac) {
            AddMacView(macs: hosts) { host in
                navigation.isAddingMac = false
                navigation.host = host.id
            } cancel: {
                navigation.isAddingMac = false
            }
        }
    }
}

#if DEBUG
/// A dashboard that shows the preview host, which answers over the loopback interface unless it is `notFound`.
@MainActor
private func previewDashboardSplitViewController(hasHost: Bool, notFound: Bool = false) -> NSSplitViewController {
    let store = PreviewSecretStore()
    let host = PairedMac(pairing: HostPairing(id: UUID(), name: "m6mini", key: Data(count: 32)), hostID: UUID())
    if hasHost { try? store.write(JSONEncoder().encode([host])) }
    let hosts = PairedMacs(store: store, name: HostPane.macName, role: .dashboard, browses: false)
    if hasHost, !notFound { connectPreviewMac(host, to: hosts, stopsAnswering: false) }
    return makeDashboardSplitViewController(hosts: hosts, navigation: DashboardNavigation())
}

#Preview("Dashboard", traits: .fixedLayout(width: 760, height: 620)) { previewDashboardSplitViewController(hasHost: true) }
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
