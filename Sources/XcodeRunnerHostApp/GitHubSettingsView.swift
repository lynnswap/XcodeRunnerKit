import SwiftUI

@MainActor
struct GitHubSettingsView: View {
    @Bindable var model: GitHubHostSettings

    var body: some View {
        Form {
            Section {
                if let account = model.account {
                    LabeledContent("Connected account") {
                        HStack {
                            Text(account.login)
                            Button("Disconnect") { Task { await model.signOut() } }
                                .disabled(!model.canDisconnect)
                        }
                    }
                } else if model.isConnecting {
                    if let authorization = model.deviceAuthorization {
                        LabeledContent("Code", value: authorization.userCode)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                        Text("Enter this code on the GitHub page that opened, then authorize the app. Enter it only on a page you opened from these settings.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("Open GitHub", destination: authorization.verificationURI)
                    } else {
                        ProgressView("Contacting GitHub…")
                    }
                    Button("Cancel") { model.cancelConnection() }
                } else {
                    Text("Connect GitHub to register runners for your repositories. The sign-in is saved in this Mac's Keychain.")
                        .foregroundStyle(.secondary)
                    Button("Connect GitHub…") { model.signIn() }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("github-sign-in")
                }
            } header: {
                Text("Account")
            } footer: {
                if model.account != nil {
                    Text("Disconnecting removes this Mac's GitHub sign-in and pauses runner management. Existing runner services and jobs continue.")
                }
            }
            if model.account != nil {
                Section {
                    ForEach(model.selectableRepositories) { repository in
                        Toggle(repository.fullName, isOn: Binding(
                            get: { model.selectedRepositoryIDs.contains(repository.id) },
                            set: { selected in
                                if selected { model.selectedRepositoryIDs.insert(repository.id) }
                                else { model.selectedRepositoryIDs.remove(repository.id) }
                            }
                        ))
                        .disabled(model.isBusy)
                    }
                    if model.isLoadingRepositories {
                        ProgressView("Loading repositories…")
                    } else if model.repositories.isEmpty {
                        Text("To list a repository here, choose Add Repositories on GitHub…, install the app on it, then choose Reload.")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        if model.selectedRepositoryIDs != model.savedRepositoryIDs {
                            Text("Unapplied changes").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add Repositories on GitHub…") { model.installApp() }
                            .disabled(model.isBusy)
                        Button("Reload") { Task { await model.reloadRepositories() } }
                            .disabled(!model.canReloadRepositories)
                        Button(model.isSavingSelection ? "Applying…" : "Apply") {
                            Task { await model.applyRepositorySelection() }
                        }
                        .disabled(model.isBusy || model.isLoadingRepositories)
                        .accessibilityIdentifier("apply-repository-selection")
                    }
                } header: {
                    Text("Repositories")
                } footer: {
                    if let manager = model.management?.manager {
                        Text("\(manager.name) registers this Mac's runners while it manages this Mac, so this selection applies after management stops.")
                    } else if model.pairedMacs?.macs.isEmpty == false {
                        Text("This Mac and the Macs it manages register runners for the selected repositories. Overview shows their status.")
                    } else {
                        Text("This Mac registers runners for the selected repositories. Overview shows their status.")
                    }
                }
            }
            if let error = model.errorMessage {
                Section { ErrorText(error) }
            }
        }
    }
}
