import AppKit
import SwiftUI

/// The Settings pane: a Mac's roles, status, GitHub sign-in, repositories, and pairings with other Macs.
@MainActor
final class OverviewViewController: NSHostingController<OverviewView> {
    init(model: OverviewModel) {
        super.init(rootView: OverviewView(model: model))
        // The split view and the window decide the pane's size.
        sizingOptions = []
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
struct OverviewView: View {
    let model: OverviewModel

    var body: some View {
        Form {
            if let connection = model.connection {
                Section { MacConnectionRows(connection: connection) }
            }
            if let management = model.management {
                MacRolesSection(model: model, management: management)
            }
            if let report = model.report, let github = model.github {
                Section(model.mac.name ?? HostPane.macName) { HostStatusRows(settings: report) }
                if let manager = github.managerName {
                    // A runner's host signs in and selects the repositories, so this Mac shows neither.
                    Section("GitHub") {
                        Text("\(manager) registers runners on \(model.mac.object) for the repositories selected there.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Group {
                        account(github)
                        if github.accountLogin != nil { repositories(github) }
                    }
                    .disabled(model.isWaitingForGitHub)
                    managedMacs
                }
                if let management = model.management {
                    HostDashboardsSection(management: management)
                }
            }
            if !model.notices.isEmpty {
                Section { ForEach(model.notices, id: \.self) { ErrorText($0) } }
            }
        }
        .formStyle(.grouped)
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
            } else if github.hasRestored {
                Text("Connect GitHub to register runners for your repositories. The sign-in is saved in \(model.mac.possessive) Keychain.")
                    .foregroundStyle(.secondary)
                Button("Connect GitHub…") { model.signIn() }
                    .disabled(github.isBusy)
                    .accessibilityIdentifier("github-sign-in")
            }
            // Without an account the repositories' section, which shows this otherwise, is hidden.
            if github.accountLogin == nil, let error = github.errorMessage { ErrorText(error) }
        } header: {
            Text("GitHub")
        } footer: {
            if github.accountLogin != nil {
                Text("Disconnecting removes \(model.mac.possessive) GitHub sign-in and pauses runner management. Existing runner services and jobs continue.")
            }
        }
    }

    /// The repositories that the app is installed on, each with its runners once it is selected, and the ones whose
    /// runners are still to be removed.
    private func repositories(_ github: GitHubReport) -> some View {
        let statuses = Dictionary(github.runnerStatuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(github.selectableRepositories.map(\.id))
        return Section {
            ForEach(github.selectableRepositories) { repository in
                Toggle(isOn: Binding(
                    get: { model.selection.contains(repository.id) },
                    set: { selected in
                        if selected { model.selection.insert(repository.id) } else { model.selection.remove(repository.id) }
                    }
                )) {
                    Text(repository.fullName)
                    if let status = statuses[repository.id] { runners(status) }
                }
                .disabled(github.isBusy)
            }
            // A repository that the app can no longer reach has no switch, and its runners are listed all the same.
            ForEach(github.runnerStatuses.filter { !listed.contains($0.id) }) { status in
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.fullName)
                    runners(status)
                }
            }
            if !github.isLoadingRepositories, !github.hasListedRepositories {
                Text("To list a repository here, choose Add Repositories on GitHub…, install the app on it, then reload the list.")
                    .foregroundStyle(.secondary)
            }
            if github.isSynchronizing { ProgressView("Synchronizing runner registrations…") }
            if let error = github.errorMessage { ErrorText(error) }
            HStack {
                if model.selection != github.savedRepositoryIDs {
                    Text("Unapplied changes").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Repositories on GitHub…") { model.addRepositories() }
                    .disabled(github.isBusy)
                Button(github.isSavingSelection ? "Applying…" : "Apply") { model.applySelection() }
                    .disabled(!model.canApplySelection)
                    .accessibilityIdentifier("apply-repository-selection")
            }
        } header: {
            HStack {
                Text("Repositories")
                Spacer()
                // The list reloads in place, so its progress takes the button's place.
                if github.isLoadingRepositories {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Loading repositories")
                        .transition(.opacity)
                } else {
                    Button("Reload", systemImage: "arrow.clockwise") { model.reloadRepositories() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(!github.canReloadRepositories)
                        .help("Reload the repositories that the app is installed on")
                        .accessibilityIdentifier("reload-repositories")
                        .transition(.opacity)
                }
            }
            .animation(.default, value: github.isLoadingRepositories)
        } footer: {
            if github.managesMacs {
                Text("\(model.mac.subject) and the Macs that it manages register runners for the selected repositories, and the counts include them all.")
            } else {
                Text("\(model.mac.subject) registers runners for the selected repositories.")
            }
        }
    }

    /// A repository's runners, under its name.
    @ViewBuilder
    private func runners(_ status: RepositoryRunnerReport) -> some View {
        Group {
            if status.isUnlinked {
                // Without a listing from GitHub, the runners still to remove are not counted.
                if status.registeredCount > 0 {
                    Text("Removing \(status.registeredCount) · \(status.busyCount) busy").monospacedDigit()
                } else {
                    Text("Removing")
                }
                if status.busyCount > 0 { Text("Busy runners are removed after their current jobs finish.") }
            } else {
                Text("\(status.onlineCount) of \(status.desiredCount) online · \(status.busyCount) busy").monospacedDigit()
            }
            if status.excessCount > 0 {
                Text("\(status.excessCount) extra registrations are retained to keep existing jobs running. The shared Xcode execution limit still applies.")
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        if let error = status.errorMessage { ErrorText(error) }
    }

    /// The Macs that the Mac manages, which the sidebar lists under Runners, and the button that pairs it with
    /// another one.
    private var managedMacs: some View {
        let count = model.managedMacCount
        return Section {
            LabeledContent {
                Button("Add Mac…") { model.addManagedMac() }
                    .disabled(!model.canAddManagedMac)
                    .accessibilityIdentifier("add-mac")
            } label: {
                Text(count == 0 ? "No other Macs" : count == 1 ? "1 other Mac" : "\(count) other Macs")
            }
        } header: {
            Text("Runners on Other Macs")
        } footer: {
            if model.canAddManagedMac {
                Text("\(model.mac.subject) registers runners on the Macs that it manages, for the selected repositories. To list a Mac here, turn off Host in its settings.")
            } else {
                Text("\(model.mac.subject) waits for a host, so it cannot manage Macs.")
            }
        }
    }
}
