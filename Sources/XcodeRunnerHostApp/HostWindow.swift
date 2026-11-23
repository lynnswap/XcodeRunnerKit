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

/// This host and its runners, including the Mac running the host.
@MainActor @Observable
final class HostWindowModel: PaneWindowModel {
    let settings: HostSettingsModel
    var pane: HostPane

    init(settings: HostSettingsModel, pane: HostPane = .overview) {
        self.settings = settings
        self.pane = pane
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
            SidebarGroup(title: "Runners", rows: [row(.mac, subtitle: report.runnerActivityTitle)] + settings.managedMacs.macs.map {
                let status = settings.managedMacs.status(of: $0.id)
                return row(.managedMac($0.id), subtitle: settings.managedMacs.runnerActivityTitle(of: $0.listed), status: .init(symbol: status.systemImage, color: status.tint))
            }),
        ]
    }

    var selectedPane: AnyHashable? { pane }
    func select(_ row: AnyHashable) {
        if let pane = row.base as? HostPane { self.pane = pane }
    }
    var title: String { pane.title(in: settings) }
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
        switch model.pane {
        case .overview:
            return OverviewViewController(model: OverviewModel(settings: settings) { [weak self] in self?.addMac() })
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
}

@MainActor
func makeHostWindowController(settings: HostSettingsModel) -> NSWindowController {
    makePaneWindowController(
        content: HostSplitViewController(model: HostWindowModel(settings: settings)),
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
