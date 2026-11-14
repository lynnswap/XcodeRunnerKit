import AppKit
import Observation
import SwiftUI

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

/// The GitHub pane: a Mac's GitHub sign-in and repository selection.
@MainActor
final class GitHubViewController: NSHostingController<GitHubPaneView> {
    init(model: GitHubPaneModel) {
        super.init(rootView: GitHubPaneView(model: model))
        // The split view and the window decide the pane's size.
        sizingOptions = []
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
struct GitHubPaneView: View {
    @Bindable var model: GitHubPaneModel

    var body: some View {
        Form {
            if let connection = model.connection {
                Section { MacConnectionRows(connection: connection) }
            }
            if let github = model.github {
                account(github)
                if github.accountLogin != nil { repositories(github) }
                if let error = github.errorMessage {
                    Section { ErrorText(error) }
                }
            }
            if let error = model.requestError {
                Section { ErrorText(error) }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isWaiting)
        .task { await model.watch() }
    }

    private func account(_ github: GitHubReport) -> some View {
        Section {
            if let login = github.accountLogin {
                LabeledContent("Connected account") {
                    HStack {
                        Text(login)
                        Button("Disconnect") { model.signOut() }
                            .disabled(!github.canDisconnect)
                    }
                }
            } else if github.isConnecting {
                if let code = github.signInCode {
                    LabeledContent("Code", value: code.userCode)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                    Text("Enter this code on the GitHub page that opened, then authorize the app. Enter it only on a page you opened from these settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Open GitHub", destination: code.verificationURI)
                } else {
                    ProgressView("Contacting GitHub…")
                }
                Button("Cancel") { model.cancelSignIn() }
            } else {
                Text("Connect GitHub to register runners for your repositories. The sign-in is saved in \(model.mac.possessive) Keychain.")
                    .foregroundStyle(.secondary)
                Button("Connect GitHub…") { model.signIn() }
                    .disabled(github.isBusy)
                    .accessibilityIdentifier("github-sign-in")
            }
        } header: {
            Text("Account")
        } footer: {
            if github.accountLogin != nil {
                Text("Disconnecting removes \(model.mac.possessive) GitHub sign-in and pauses runner management. Existing runner services and jobs continue.")
            }
        }
    }

    private func repositories(_ github: GitHubReport) -> some View {
        Section {
            ForEach(github.selectableRepositories) { repository in
                Toggle(repository.fullName, isOn: Binding(
                    get: { model.selection.contains(repository.id) },
                    set: { selected in
                        if selected { model.selection.insert(repository.id) } else { model.selection.remove(repository.id) }
                    }
                ))
                .disabled(github.isBusy)
            }
            if github.isLoadingRepositories {
                ProgressView("Loading repositories…")
            } else if !github.hasListedRepositories {
                Text("To list a repository here, choose Add Repositories on GitHub…, install the app on it, then choose Reload.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if model.selection != github.savedRepositoryIDs {
                    Text("Unapplied changes").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Repositories on GitHub…") { model.addRepositories() }
                    .disabled(github.isBusy)
                Button("Reload") { model.reloadRepositories() }
                    .disabled(!github.canReloadRepositories)
                Button(github.isSavingSelection ? "Applying…" : "Apply") { model.applySelection() }
                    .disabled(github.isBusy || github.isLoadingRepositories)
                    .accessibilityIdentifier("apply-repository-selection")
            }
        } header: {
            Text("Repositories")
        } footer: {
            if let manager = github.managerName {
                Text("\(manager) registers \(model.mac.possessive) runners while it manages \(model.mac.object), so this selection applies after management stops.")
            } else if github.managesMacs {
                Text("\(model.mac.subject) and the Macs it manages register runners for the selected repositories. Overview shows their status.")
            } else {
                Text("\(model.mac.subject) registers runners for the selected repositories. Overview shows their status.")
            }
        }
    }
}
