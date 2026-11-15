import AppKit
import SwiftUI

/// The Overview pane: a Mac's status, setup steps, repositories, and pairings with other Macs.
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
            if let report = model.report, let github = model.github {
                // A managed Mac's runners are registered by its managing host, so it needs no sign-in or selection.
                if github.managerName == nil, github.hasRestored && (github.accountLogin == nil || github.savedRepositoryIDs.isEmpty) {
                    setup(github)
                }
                Section(model.mac.name ?? HostPane.macName) { HostStatusRows(settings: report) }
                Section {
                    if let manager = github.managerName {
                        Text("\(manager) registers runners on \(model.mac.object) for the repositories selected there.")
                            .foregroundStyle(.secondary)
                    } else {
                        repositories(github)
                    }
                } header: {
                    Text("Repositories")
                } footer: {
                    if github.managesMacs { Text("Counts include the Macs that \(model.mac.object) manages.") }
                }
                managedMacs
                if let management = model.management {
                    HostManagementSection(model: model, management: management)
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

    /// The Macs that the Mac manages, which the sidebar lists, and the button that pairs it with another one.
    private var managedMacs: some View {
        let count = model.managedMacCount
        return Section {
            LabeledContent {
                Button("Add Mac…") { model.addManagedMac() }
                    .disabled(!model.canAddManagedMac)
                    .accessibilityIdentifier("add-mac")
            } label: {
                Text(count == 0 ? "No Macs" : count == 1 ? "1 Mac" : "\(count) Macs")
            }
        } header: {
            Text("Managed Macs")
        } footer: {
            if model.canAddManagedMac {
                Text("\(model.mac.subject) registers runners on the Macs that it manages, for the repositories selected in GitHub. Choose Allow Management… on a Mac to list it here.")
            } else {
                Text("A Mac that another Mac manages, or that waits for one, cannot manage Macs.")
            }
        }
    }

    @ViewBuilder
    private func repositories(_ github: GitHubReport) -> some View {
        if github.isSynchronizing { ProgressView("Synchronizing runner registrations…") }
        if github.runnerStatuses.isEmpty && !github.isSynchronizing {
            Text(github.savedRepositoryIDs.isEmpty
                ? "No repositories are selected."
                : "Runner counts appear after the next synchronization.")
                .foregroundStyle(.secondary)
        }
        ForEach(github.runnerStatuses) { status in
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(status.fullName) {
                    if status.isUnlinked {
                        // Without a listing from GitHub, the runners still to remove are not counted.
                        if status.registeredCount > 0 {
                            Text("Removing \(status.registeredCount) · \(status.busyCount) busy").monospacedDigit()
                        } else {
                            Text("Removing")
                        }
                    } else {
                        Text("\(status.onlineCount) of \(status.desiredCount) online · \(status.busyCount) busy")
                            .monospacedDigit()
                    }
                }
                if status.isUnlinked, status.busyCount > 0 {
                    Text("Busy runners are removed after their current jobs finish.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = status.errorMessage { ErrorText(error) }
                if status.excessCount > 0 {
                    Text("\(status.excessCount) extra registrations are retained to keep existing jobs running. The shared Xcode execution limit still applies.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        if let error = github.errorMessage { ErrorText(error) }
    }

    /// The first unfinished step offers its action, so the order of setup stays visible.
    private func setup(_ github: GitHubReport) -> some View {
        let steps = [
            github.accountLogin != nil,
            !github.selectableRepositories.isEmpty,
            !github.savedRepositoryIDs.isEmpty,
        ]
        let current = steps.firstIndex(of: false)
        return Section("Get Started") {
            setupStep("Sign in to GitHub", isDone: steps[0], isCurrent: current == 0) {
                Button("Connect GitHub…") { model.connectGitHub() }
                    .disabled(github.isBusy)
            }
            setupStep("Install the app on your repositories", isDone: steps[1], isCurrent: current == 1) {
                Button("Add Repositories on GitHub…") { model.addRepositories() }
                Button("Reload") { model.reloadRepositories() }
                    .disabled(!github.canReloadRepositories)
            }
            setupStep("Choose the repositories to run", isDone: steps[2], isCurrent: current == 2) {
                Button("Choose Repositories…") { model.chooseRepositories() }
            }
        }
    }

    private func setupStep(
        _ title: String, isDone: Bool, isCurrent: Bool, @ViewBuilder actions: () -> some View
    ) -> some View {
        LabeledContent {
            if isCurrent { HStack { actions() } }
        } label: {
            Label(title, systemImage: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? .secondary : .primary)
        }
    }
}
