import AppKit
import Observation

/// A pane in the host window's sidebar.
enum HostPane: Hashable {
    /// The Mac's role, status, GitHub sign-in, repositories, and pairings.
    case overview
    /// This Mac's runner services and execution settings, listed under Runners.
    case mac
    /// A Mac that this host manages, listed under Runners.
    case managedMac(HostPairing.ID)

    @MainActor func title(in settings: HostSettingsModel) -> String {
        switch self {
        case .overview: "Settings"
        case .mac: Self.macName
        case .managedMac(let id): settings.managedMacs.mac(id)?.name ?? "Mac"
        }
    }

    var icon: SidebarRow.Icon {
        switch self {
        case .overview: .symbol("gear")
        case .mac, .managedMac: .symbol("desktopcomputer")
        }
    }

    /// The computer name set in Sharing settings.
    static let macName = Host.current().localizedName ?? "This Mac"
}

/// What the host window shows: this Mac's panes and the Macs that it manages in the sidebar, the hosts on other Macs
/// that this Mac shows as a dashboard after them, and the selected pane.
@MainActor @Observable
final class HostWindowModel: PaneWindowModel {
    let settings: HostSettingsModel
    /// The hosts on other Macs that this Mac paired with as a dashboard.
    let shownHosts: PairedMacs?
    /// The pane of this Mac that is selected in the sidebar, unless one of another host is. Selecting it leaves the
    /// other host's pane.
    var pane: HostPane { didSet { shownHostPane = nil } }
    /// The pane of a host on another Mac that the person selected in place of `pane`.
    var shownHostPane: DashboardPane?

    init(settings: HostSettingsModel, shownHosts: PairedMacs? = nil, pane: HostPane = .overview) {
        self.settings = settings
        self.shownHosts = shownHosts
        self.pane = pane
    }

    /// The selected pane of another host, while this Mac still shows that host. A pane leaves with its host.
    var shownPane: (pane: DashboardPane, hosts: PairedMacs, host: PairedMac)? {
        guard let shownHosts, let shownHostPane, let host = shownHosts.mac(shownHostPane.host) else { return nil }
        return (shownHostPane, shownHosts, host)
    }

    var sidebarGroups: [SidebarGroup] {
        let report = HostSettingsReport(settings)
        func row(_ pane: HostPane, subtitle: String?, status: SidebarRow.Status? = nil) -> SidebarRow {
            SidebarRow(pane: pane, title: pane.title(in: settings), subtitle: subtitle, icon: pane.icon, status: status)
        }
        return [
            SidebarGroup(title: nil, rows: [
                row(.overview, subtitle: report.stateTitle, status: .init(symbol: report.stateSymbol, color: report.stateTint)),
            ]),
            SidebarGroup(title: "Runners", rows: [row(.mac, subtitle: report.runnerCountTitle)] + settings.managedMacs.macs.map {
                let status = settings.managedMacs.status(of: $0.id)
                return row(.managedMac($0.id), subtitle: status.title, status: .init(symbol: status.systemImage, color: status.tint))
            }),
        ] + (shownHosts.map { DashboardWindowModel.sidebarGroups(of: $0, namingHosts: true) } ?? [])
    }

    var selectedPane: AnyHashable? { shownPane.map { AnyHashable($0.pane) } ?? AnyHashable(pane) }

    func select(_ pane: AnyHashable) {
        if let pane = pane.base as? HostPane {
            self.pane = pane
        } else if let pane = pane.base as? DashboardPane {
            shownHostPane = pane
        }
    }

    var title: String {
        shownPane.flatMap { DashboardWindowModel.title(of: $0.pane, in: $0.hosts) } ?? pane.title(in: settings)
    }
}

/// The host window's content: this Mac's panes and the Macs that it manages in a sidebar beside the selected pane.
@MainActor
final class HostSplitViewController: PaneSplitViewController {
    private let model: HostWindowModel
    private var settings: HostSettingsModel { model.settings }

    init(model: HostWindowModel) {
        self.model = model
        super.init(model: model, autosaveName: "XcodeHomeRunnerSettings")
    }

    required init?(coder: NSCoder) { nil }

    override func makePaneViewController() -> NSViewController {
        if let shown = model.shownPane {
            let host = shown.host.id
            return makeDashboardPaneViewController(
                shown.pane, of: shown.host, in: shown.hosts, addMac: { [weak self] in self?.addMac(managedBy: host) },
                show: { [model] in model.shownHostPane = $0 }
            )
        }
        switch model.pane {
        case .overview:
            var showHost: (@MainActor () -> Void)?
            if model.shownHosts != nil { showHost = { [weak self] in self?.showHost() } }
            return OverviewViewController(
                model: OverviewModel(settings: settings, addMac: { [weak self] in self?.addMac() }, showHost: showHost)
            )
        case .mac: return MacViewController(model: MacPaneModel(settings: settings))
        case .managedMac(let id):
            return MacViewController(model: MacPaneModel(
                macs: settings.managedMacs, id: id,
                // This Mac registers the Mac's runners, so a changed limit or label is applied to them here.
                registrationsChanged: { [settings] in await settings.github.synchronize() },
                removed: { [model] in model.pane = .mac }
            ))
        }
    }

    /// Pairs this Mac with a Mac on the local network for it to manage, and shows that Mac.
    private func addMac() {
        guard !isAddingMac, settings.canAddMacs else { return }
        presentAddMacSheet(for: settings.managedMacs) { [model] mac in model.pane = .managedMac(mac.id) }
    }

    /// Pairs this Mac as a dashboard with a host on another Mac, and shows that host.
    private func showHost() {
        guard !isAddingMac, let hosts = model.shownHosts else { return }
        presentAddMacSheet(for: hosts) { [model] host in model.shownHostPane = .overview(host.id) }
    }

    /// Pairs a host that this Mac shows with a Mac for it to manage, and shows that Mac.
    private func addMac(managedBy host: HostPairing.ID) {
        guard !isAddingMac, let hosts = model.shownHosts else { return }
        presentAddMacSheet(for: hosts.macsManaged(by: host)) { [model] mac in
            model.shownHostPane = .managedMac(mac.id, host: host)
        }
    }
}

/// Creates the host window.
///
/// - Parameter shownHosts: The hosts on other Macs that this Mac paired with as a dashboard.
@MainActor
func makeHostWindowController(settings: HostSettingsModel, shownHosts: PairedMacs) -> NSWindowController {
    makePaneWindowController(
        content: HostSplitViewController(model: HostWindowModel(settings: settings, shownHosts: shownHosts)),
        autosaveName: "XcodeHomeRunnerSettings"
    )
}

#if DEBUG
#Preview("New Mac") { HostPreview.hostWindow(pane: .overview, isSignedIn: false) }
#Preview("Settings") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, pairing: .managing)
}
#Preview("Mac") { HostPreview.hostWindow(pane: .mac, isSignedIn: true) }
#Preview("Mac With Removed Xcode") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, savedXcodeIsRemoved: true)
}
#Preview("Paused Mac") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, isPaused: true)
}
#Preview("Paused Settings") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, isPaused: true)
}
#Preview("Waiting to Pair") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, pairing: .waitingToPair)
}
#Preview("Pairing Request") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, pairing: .asked(by: "Mac mini"))
}
#Preview("Managed by Another Mac") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, pairing: .managed(by: "Mac mini"))
}
#Preview("Shown on Dashboards") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, pairing: .shown(on: ["MacBook Pro", "Mac Studio"]))
}
#Preview("Dashboard Pairing Request") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, pairing: .askedToShow(by: "MacBook Pro"))
}
#Preview("Managed Mac") {
    HostPreview.hostWindow(
        pane: .managedMac(HostPreview.managedMacs[0].id), isSignedIn: true, pairing: .managingConnected(stopsAnswering: false)
    )
}
#Preview("Managed Mac Not Responding") {
    HostPreview.hostWindow(
        pane: .managedMac(HostPreview.managedMacs[0].id), isSignedIn: true, pairing: .managingConnected(stopsAnswering: true)
    )
}
#Preview("Managed Mac Not Found") {
    HostPreview.hostWindow(pane: .managedMac(HostPreview.managedMacs[0].id), isSignedIn: true, pairing: .managing)
}
#endif
