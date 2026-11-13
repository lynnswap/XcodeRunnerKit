import SwiftUI

/// What the GitHub controls do: on this Mac, or on the host that a dashboard shows.
@MainActor
struct GitHubActions {
    let signIn: () -> Void
    let cancelSignIn: () -> Void
    let signOut: () -> Void
    /// Opens the page that installs the GitHub App on repositories.
    let addRepositories: () -> Void
    let reloadRepositories: () -> Void
    let applySelection: () -> Void
}

extension GitHubHostSettings {
    /// The GitHub controls of this Mac's own window.
    var actions: GitHubActions {
        GitHubActions(
            signIn: { self.signIn() }, cancelSignIn: { self.cancelConnection() },
            signOut: { Task { await self.signOut() } }, addRepositories: { self.installApp() },
            reloadRepositories: { Task { await self.reloadRepositories() } },
            applySelection: { Task { await self.applyRepositorySelection() } }
        )
    }
}

/// How a pane names the Mac it shows: this Mac in its own window, or a host by name on a dashboard.
struct MacReference {
    /// `nil` for this Mac.
    let name: String?

    static let thisMac = MacReference(name: nil)

    /// The Mac at the start of a sentence.
    var subject: String { name ?? "This Mac" }
    var object: String { name ?? "this Mac" }
    var possessive: String { name.map { $0 + "'s" } ?? "this Mac's" }
}

/// A Mac's GitHub sign-in and repository selection, in its own window or on a dashboard.
@MainActor
struct GitHubSettingsView: View {
    let github: GitHubReport
    /// The repository selection being edited.
    @Binding var selection: Set<Int>
    let mac: MacReference
    /// Whether a request to the Mac is in progress, which holds the controls until it answers.
    var isRequesting = false
    /// Why the Mac refused the last request from a dashboard, or why it did not confirm it.
    var requestError: String?
    let actions: GitHubActions

    var body: some View {
        Form {
            Section {
                if let login = github.accountLogin {
                    LabeledContent("Connected account") {
                        HStack {
                            Text(login)
                            Button("Disconnect", action: actions.signOut)
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
                    Button("Cancel", action: actions.cancelSignIn)
                } else {
                    Text("Connect GitHub to register runners for your repositories. The sign-in is saved in \(mac.possessive) Keychain.")
                        .foregroundStyle(.secondary)
                    Button("Connect GitHub…", action: actions.signIn)
                        .disabled(github.isBusy)
                        .accessibilityIdentifier("github-sign-in")
                }
            } header: {
                Text("Account")
            } footer: {
                if github.accountLogin != nil {
                    Text("Disconnecting removes \(mac.possessive) GitHub sign-in and pauses runner management. Existing runner services and jobs continue.")
                }
            }
            if github.accountLogin != nil {
                Section {
                    ForEach(github.selectableRepositories) { repository in
                        Toggle(repository.fullName, isOn: Binding(
                            get: { selection.contains(repository.id) },
                            set: { selected in
                                if selected { selection.insert(repository.id) } else { selection.remove(repository.id) }
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
                        if selection != github.savedRepositoryIDs {
                            Text("Unapplied changes").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add Repositories on GitHub…", action: actions.addRepositories)
                            .disabled(github.isBusy)
                        Button("Reload", action: actions.reloadRepositories)
                            .disabled(!github.canReloadRepositories)
                        Button(github.isSavingSelection ? "Applying…" : "Apply", action: actions.applySelection)
                            .disabled(github.isBusy || github.isLoadingRepositories)
                            .accessibilityIdentifier("apply-repository-selection")
                    }
                } header: {
                    Text("Repositories")
                } footer: {
                    if let manager = github.managerName {
                        Text("\(manager) registers \(mac.possessive) runners while it manages \(mac.object), so this selection applies after management stops.")
                    } else if github.managesMacs {
                        Text("\(mac.subject) and the Macs it manages register runners for the selected repositories. Overview shows their status.")
                    } else {
                        Text("\(mac.subject) registers runners for the selected repositories. Overview shows their status.")
                    }
                }
            }
            if let error = github.errorMessage {
                Section { ErrorText(error) }
            }
            if let requestError {
                Section { ErrorText(requestError) }
            }
        }
        .disabled(isRequesting)
    }
}
