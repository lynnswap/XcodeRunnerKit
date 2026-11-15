import Foundation
import Observation

/// What the Overview pane shows and does for a Mac: this Mac in its own window, or a host on a dashboard.
@MainActor @Observable
final class OverviewModel {
    private enum Source {
        case thisMac(HostSettingsModel)
        case host(PairedMacs, PairedMac)
    }

    private let source: Source
    private let showGitHub: @MainActor () -> Void

    /// - Parameter showGitHub: Shows the GitHub pane, where the sign-in code and the repository selection are.
    init(settings: HostSettingsModel, showGitHub: @escaping @MainActor () -> Void) {
        source = .thisMac(settings)
        self.showGitHub = showGitHub
    }

    /// - Parameters:
    ///   - host: A host that the dashboard shows.
    ///   - showGitHub: Shows the host's GitHub pane.
    init(hosts: PairedMacs, host: PairedMac, showGitHub: @escaping @MainActor () -> Void) {
        source = .host(hosts, host)
        self.showGitHub = showGitHub
    }

    var mac: MacReference {
        switch source {
        case .thisMac: .thisMac
        case .host(_, let host): MacReference(name: host.name)
        }
    }

    /// The Mac's status. A dashboard has none while the host does not answer.
    var report: HostSettingsReport? {
        switch source {
        case .thisMac(let settings): HostSettingsReport(settings)
        case .host(let hosts, let host): hosts.answer(of: host.id)?.report
        }
    }

    /// The Mac's sign-in and repositories. A dashboard has none while the host does not answer.
    var github: GitHubReport? {
        switch source {
        case .thisMac(let settings): settings.github.report
        case .host(let hosts, let host): hosts.answer(of: host.id)?.github
        }
    }

    /// The connection to a host that does not answer, which the pane shows in place of the host's status.
    var connection: MacConnection? {
        guard case .host(let hosts, let host) = source, hosts.answer(of: host.id) == nil else { return nil }
        return MacConnection(of: host.listed, in: hosts)
    }

    /// What a dashboard's last requests to the host left to tell: a refusal, or a Mac that was removed but could not
    /// be told. Removing one of the host's Macs returns to this pane, where its notice stays visible.
    var notices: [String] {
        guard case .host(let hosts, let host) = source, let answer = hosts.answer(of: host.id) else { return [] }
        return [answer.settings.githubError, hosts.macsManaged(by: host.id).message].compactMap { $0 }
    }

    /// Shows the GitHub pane and starts the sign-in, whose code appears there.
    func connectGitHub() {
        showGitHub()
        switch source {
        case .thisMac(let settings): settings.github.signIn()
        case .host(let hosts, let host): Task { await hosts.signIn(to: host.id) }
        }
    }

    /// Opens the page that installs the GitHub App on repositories.
    func addRepositories() {
        switch source {
        case .thisMac(let settings): settings.github.installApp()
        case .host(let hosts, let host): hosts.addRepositories(to: host.id)
        }
    }

    func reloadRepositories() {
        switch source {
        case .thisMac(let settings): Task { await settings.github.reloadRepositories() }
        case .host(let hosts, let host): Task { await hosts.reloadRepositories(of: host.id) }
        }
    }

    func chooseRepositories() { showGitHub() }

    /// Reads a host's settings every few seconds until the task is cancelled. This Mac's settings need no reading.
    func watch() async {
        if case .host(let hosts, let host) = source { await hosts.watchSettings(of: host.id) }
    }
}
