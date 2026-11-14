import AppKit
import Observation
import SwiftUI

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

/// The Overview pane: a Mac's status, setup steps, and repositories.
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
            }
            if !model.notices.isEmpty {
                Section { ForEach(model.notices, id: \.self) { ErrorText($0) } }
            }
        }
        .formStyle(.grouped)
        .task { await model.watch() }
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

/// A Mac's host status and Xcode job counts.
@MainActor
struct HostStatusRows: View {
    let settings: HostSettingsReport

    var body: some View {
        LabeledContent("Status") {
            // A paused Mac runs as its person chose, so it does not look like a host that needs attention.
            Label {
                Text(settings.showsPaused ? "Paused" : settings.hostState.rawValue)
            } icon: {
                Image(systemName: settings.showsPaused ? "pause.circle.fill" : settings.hostState.systemImage)
                    .foregroundStyle(settings.showsPaused ? .secondary : settings.hostState.tint)
            }
        }
        LabeledContent("Xcode jobs") { Text(settings.jobSummary).monospacedDigit() }
        Text(settings.admissionMessage).font(.callout).foregroundStyle(.secondary)
        if let error = settings.storageError { ErrorText(error) }
        if let error = settings.poolError { ErrorText(error) }
    }
}

private extension HostState {
    var systemImage: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .starting, .preparingStorage: "circle.dotted"
        case .waitingForStorage: "clock"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .waitingForStorage: .orange
        case .needsAttention: .red
        case .starting, .preparingStorage, .stopping: .secondary
        }
    }
}

struct ErrorText: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
    }
}
