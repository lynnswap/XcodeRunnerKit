import Foundation
import Observation

/// What the GitHub pane shows and does for a Mac: this Mac in its own window, or a host on a dashboard.
@MainActor @Observable
final class GitHubPaneModel {
    private enum Source {
        case thisMac(HostSettingsModel)
        case host(PairedMacs, PairedMac)
    }

    private let source: Source

    init(settings: HostSettingsModel) {
        source = .thisMac(settings)
    }

    /// - Parameter host: A host that the dashboard shows.
    init(hosts: PairedMacs, host: PairedMac) {
        source = .host(hosts, host)
    }

    var mac: MacReference {
        switch source {
        case .thisMac: .thisMac
        case .host(_, let host): MacReference(name: host.name)
        }
    }

    /// The Mac's sign-in and repositories. A dashboard has none while the host does not answer.
    var github: GitHubReport? {
        switch source {
        case .thisMac(let settings): settings.github.report
        case .host(let hosts, let host): hosts.answer(of: host.id)?.github
        }
    }

    /// The repository selection being edited.
    var selection: Set<Int> {
        get {
            switch source {
            case .thisMac(let settings): settings.github.selectedRepositoryIDs
            case .host(let hosts, let host): hosts.settings(of: host.id)?.selectedRepositoryIDs ?? []
            }
        }
        set {
            switch source {
            case .thisMac(let settings): settings.github.selectedRepositoryIDs = newValue
            case .host(let hosts, let host): hosts.settings(of: host.id)?.selectedRepositoryIDs = newValue
            }
        }
    }

    /// Whether the controls wait: for a host to answer a request, or for this Mac to apply a job limit, which changes
    /// the runners that it registers.
    var isWaiting: Bool {
        switch source {
        case .thisMac(let settings): settings.isSaving
        case .host(let hosts, let host): hosts.settings(of: host.id)?.isChangingGitHub ?? false
        }
    }

    /// Why a host refused the last request from the dashboard, or why it did not confirm it.
    var requestError: String? {
        guard case .host(let hosts, let host) = source else { return nil }
        return hosts.answer(of: host.id)?.settings.githubError
    }

    /// The connection to a host that does not answer, which the pane shows in place of the host's settings.
    var connection: MacConnection? {
        guard case .host(let hosts, let host) = source, hosts.answer(of: host.id) == nil else { return nil }
        return MacConnection(of: host.listed, in: hosts)
    }

    func signIn() {
        switch source {
        case .thisMac(let settings): settings.github.signIn()
        case .host(let hosts, let host): Task { await hosts.signIn(to: host.id) }
        }
    }

    func cancelSignIn() {
        switch source {
        case .thisMac(let settings): settings.github.cancelConnection()
        case .host(let hosts, let host): Task { await hosts.cancelSignIn(to: host.id) }
        }
    }

    func signOut() {
        switch source {
        case .thisMac(let settings): Task { await settings.github.signOut() }
        case .host(let hosts, let host): Task { await hosts.signOut(of: host.id) }
        }
    }

    /// Opens the page that installs the GitHub App on repositories. A host's page opens in this Mac's browser.
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

    func applySelection() {
        switch source {
        case .thisMac(let settings): Task { await settings.github.applyRepositorySelection() }
        case .host(let hosts, let host): Task { await hosts.applyRepositorySelection(of: host.id) }
        }
    }

    /// Reads a host's settings every few seconds until the task is cancelled. This Mac's settings need no reading.
    func watch() async {
        if case .host(let hosts, let host) = source { await hosts.watchSettings(of: host.id) }
    }
}
