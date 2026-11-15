import AppKit
import SwiftUI

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
                        Button("Disconnect", role: .destructive) { model.signOut() }
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
