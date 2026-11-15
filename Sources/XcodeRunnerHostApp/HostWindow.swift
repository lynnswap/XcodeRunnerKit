import AppKit
import Observation

/// A pane in the host window's sidebar.
enum HostPane: Hashable {
    case overview
    case github
    /// This Mac's runner services and execution settings, listed under Runners.
    case mac
    /// A Mac that this host manages, listed under Runners.
    case managedMac(HostPairing.ID)

    @MainActor func title(in settings: HostSettingsModel) -> String {
        switch self {
        case .overview: "Overview"
        case .github: "GitHub"
        case .mac: Self.macName
        case .managedMac(let id): settings.managedMacs.mac(id)?.name ?? "Mac"
        }
    }

    var icon: SidebarRow.Icon {
        switch self {
        case .overview: .symbol("gauge.with.dots.needle.50percent")
        case .github: .template("github-mark")
        case .mac, .managedMac: .symbol("desktopcomputer")
        }
    }

    /// The computer name set in Sharing settings.
    static let macName = Host.current().localizedName ?? "This Mac"
}

/// What the host window shows: this Mac's panes and the Macs that it manages in the sidebar, and the selected pane.
@MainActor @Observable
final class HostWindowModel: PaneWindowModel {
    let settings: HostSettingsModel
    /// The pane that is selected in the sidebar. A pane always stays selected.
    var pane: HostPane

    init(settings: HostSettingsModel, pane: HostPane = .overview) {
        self.settings = settings
        self.pane = pane
    }

    var sidebarGroups: [SidebarGroup] {
        func row(_ pane: HostPane) -> SidebarRow { SidebarRow(pane: pane, title: pane.title(in: settings), icon: pane.icon) }
        return [
            SidebarGroup(title: nil, rows: [row(.overview), row(.github)]),
            SidebarGroup(title: "Runners", rows: [row(.mac)] + settings.managedMacs.macs.map { row(.managedMac($0.id)) }),
        ]
    }

    var selectedPane: AnyHashable? { pane }

    func select(_ pane: AnyHashable) {
        if let pane = pane.base as? HostPane { self.pane = pane }
    }

    var title: String { pane.title(in: settings) }
}

/// The host window's content: this Mac's panes and the Macs that it manages in a sidebar beside the selected pane, with
/// Add Mac in the toolbar.
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
            OverviewViewController(model: OverviewModel(settings: settings) { [model] in model.pane = .github })
        case .github: GitHubViewController(model: GitHubPaneModel(settings: settings))
        case .mac: MacViewController(model: MacPaneModel(settings: settings))
        case .managedMac(let id):
            MacViewController(model: MacPaneModel(
                macs: settings.managedMacs, id: id,
                // This Mac registers the Mac's runners, so a changed limit or label is applied to them here.
                registrationsChanged: { [settings] in await settings.github.synchronize() },
                removed: { [model] in model.pane = .mac }
            ))
        }
    }

    override var addMacToolTip: String {
        "Pair a Mac on the local network so that this Mac manages its runners. A Mac that another Mac manages cannot add Macs."
    }

    override var canAddMac: Bool { super.canAddMac && settings.canAddMacs }

    override func addMac(_ sender: Any?) {
        guard canAddMac else { return }
        presentAddMacSheet(for: settings.managedMacs) { [model] mac in model.pane = .managedMac(mac.id) }
    }
}

/// Creates the host window.
@MainActor
func makeHostWindowController(settings: HostSettingsModel) -> NSWindowController {
    makePaneWindowController(
        content: HostSplitViewController(model: HostWindowModel(settings: settings)), autosaveName: "XcodeHomeRunnerSettings"
    )
}

#if DEBUG
#Preview("New Mac") { HostPreview.hostWindow(pane: .overview, isSignedIn: false) }
#Preview("Overview") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, pairing: .managing)
}
#Preview("GitHub") { HostPreview.hostWindow(pane: .github, isSignedIn: true) }
#Preview("GitHub Signed Out") { HostPreview.hostWindow(pane: .github, isSignedIn: false) }
#Preview("Mac") { HostPreview.hostWindow(pane: .mac, isSignedIn: true) }
#Preview("Mac With Removed Xcode") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, savedXcodeIsRemoved: true)
}
#Preview("Paused Mac") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, isPaused: true)
}
#Preview("Paused Overview") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, isPaused: true)
}
#Preview("Waiting to Pair") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, pairing: .waitingToPair)
}
#Preview("Pairing Request") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, pairing: .asked(by: "Mac mini"))
}
#Preview("Managed by Another Mac") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, pairing: .managed(by: "Mac mini"))
}
#Preview("Shown on Dashboards") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, pairing: .shown(on: ["MacBook Pro", "Mac Studio"]))
}
#Preview("Dashboard Pairing Request") {
    HostPreview.hostWindow(pane: .mac, isSignedIn: true, pairing: .askedToShow(by: "MacBook Pro"))
}
#Preview("Overview Managed by Another Mac") {
    HostPreview.hostWindow(pane: .overview, isSignedIn: true, pairing: .managed(by: "Mac mini"))
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
