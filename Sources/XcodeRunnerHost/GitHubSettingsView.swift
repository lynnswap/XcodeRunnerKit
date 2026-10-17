import SwiftUI

@MainActor
struct GitHubSettingsView: View {
    @Bindable var model: GitHubHostSettings

    var body: some View {
        Section("GitHub") {
            if model.hasPendingApp {
                Button("Retry Saving App") { model.retrySavingApp() }
                    .disabled(model.isConnecting || model.isSynchronizing)
                    .accessibilityIdentifier("create-github-app")
            }
            if let account = model.account {
                LabeledContent("Connected account", value: account.login)
                HStack {
                    Button("Reload Repositories") { Task { await model.loadRepositories() } }
                        .disabled(model.isLoadingRepositories || model.isConnecting || model.isSynchronizing)
                    Button("Install App…") { model.installApp() }
                        .disabled(model.isConnecting || model.isSynchronizing)
                    Button("Disconnect") { Task { await model.signOut() } }
                        .disabled(model.isConnecting || model.isSynchronizing || model.isLoadingRepositories)
                }
                Text("Choose the repositories this Mac should accept jobs from. Apply the execution limit below to register their runners.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(model.selectableRepositories) { repository in
                    Toggle(repository.fullName, isOn: Binding(
                        get: { model.selectedRepositoryIDs.contains(repository.id) },
                        set: { selected in
                            if selected { model.selectedRepositoryIDs.insert(repository.id) }
                            else { model.selectedRepositoryIDs.remove(repository.id) }
                        }
                    ))
                    .disabled(model.isSynchronizing || model.isConnecting)
                }
                if model.isLoadingRepositories {
                    ProgressView("Loading repositories…")
                } else if model.repositories.isEmpty {
                    Text("Install the app on your account and grant it access to the repositories, then reload this list.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Disconnecting pauses runner management. Existing runner services and jobs continue.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TextField("Organization (optional)", text: $model.organizationInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isConnecting || model.isSynchronizing)
                Text("Leave blank to create the app on your personal account. For organization repositories, enter the organization that will own the app.")
                    .font(.callout).foregroundStyle(.secondary)
                if !model.hasPendingApp {
                    Button(model.isConnecting ? "Waiting for GitHub…" : "Create GitHub App…") { model.createApp() }
                        .disabled(model.isConnecting || model.isSynchronizing)
                        .accessibilityIdentifier("create-github-app")
                }
                Text("Create the GitHub App from your browser. Permissions are filled in automatically, and its credentials are saved in Keychain. Install it on your account, then sign in.")
                    .font(.callout).foregroundStyle(.secondary)
                if !model.clientIDInput.isEmpty {
                    HStack {
                        Button("Install App…") { model.installApp() }
                        Button("Sign In…") { model.signIn() }
                            .accessibilityIdentifier("github-sign-in")
                    }
                    .disabled(model.isConnecting || model.isSynchronizing)
                }
            }
            if model.isConnecting {
                if let authorization = model.deviceAuthorization {
                    LabeledContent("Enter this code on GitHub", value: authorization.userCode)
                        .textSelection(.enabled)
                    Link("Open GitHub", destination: authorization.verificationURI)
                }
                Button("Cancel") { model.cancelConnection() }
            }
            DisclosureGroup("Existing GitHub App") {
                TextField("Client ID", text: $model.clientIDInput)
                    .textFieldStyle(.roundedBorder)
                TextField("App slug", text: $model.appSlugInput)
                    .textFieldStyle(.roundedBorder)
                Text("For an app created elsewhere, enable Device Flow in its GitHub settings. Apps created here need no manual configuration.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(model.isConnecting || model.isSynchronizing || model.account != nil)
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
