import SwiftUI

@MainActor
struct GitHubSettingsView: View {
    @Bindable var model: GitHubHostSettings

    var body: some View {
        Section("GitHub") {
            if let account = model.account {
                LabeledContent("Connected account", value: account.login)
                Text("Choose the repositories this Mac runs jobs for, then apply the selection to register their runners.")
                    .font(.callout).foregroundStyle(.secondary)
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
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.selectedRepositoryIDs != model.savedRepositoryIDs {
                    Text("Repository selection has unapplied changes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.isSavingSelection ? "Saving…" : "Apply Repository Selection") {
                        Task { await model.applyRepositorySelection() }
                    }
                    .disabled(model.isBusy || model.isLoadingRepositories)
                    .accessibilityIdentifier("apply-repository-selection")
                    Button("Add Repositories on GitHub…") { model.installApp() }
                        .disabled(model.isBusy)
                    Button("Reload") { Task { await model.reloadRepositories() } }
                        .disabled(!model.canReloadRepositories)
                }
                Button("Disconnect") { Task { await model.signOut() } }
                    .disabled(!model.canDisconnect)
                Text("Disconnecting removes this Mac's GitHub sign-in and pauses runner management. Existing runner services and jobs continue.")
                    .font(.callout).foregroundStyle(.secondary)
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
                    .font(.callout).foregroundStyle(.secondary)
                Button("Connect GitHub…") { model.signIn() }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("github-sign-in")
            }
            if model.isSynchronizing { ProgressView("Synchronizing runner registrations…") }
            ForEach(model.runnerStatuses) { status in
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.repository.fullName).font(.headline)
                    Text("Target \(status.desiredCount) · Registered \(status.registeredCount) · Online \(status.onlineCount) · Busy \(status.busyCount)")
                        .font(.callout).monospacedDigit()
                    if let error = status.errorMessage {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if status.excessCount > 0 {
                        Text("\(status.excessCount) extra registrations are retained to keep existing jobs running. The shared Xcode execution limit still applies.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}
