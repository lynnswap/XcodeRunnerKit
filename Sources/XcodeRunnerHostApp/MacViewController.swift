import AppKit
import SwiftUI

/// A Mac's pane: its status, what its runners take, and its execution settings.
@MainActor
final class MacViewController: NSHostingController<MacPaneView>, SavingPaneViewController {
    let saving: any PaneSaving

    init(model: MacPaneModel) {
        saving = model
        super.init(rootView: MacPaneView(model: model))
        // The split view and the window decide the pane's size.
        sizingOptions = []
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
struct MacPaneView: View {
    let model: MacPaneModel

    var body: some View {
        content.task { await model.watch() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isRemoved {
            ContentUnavailableView("This Mac was removed", systemImage: "desktopcomputer")
        } else {
            Form {
                if model.report?.resourceSample != nil {
                    RunnerResourceGraphs(history: model.resourceHistory)
                }
                OverviewSection(model: model)
                if let report = model.report {
                    SimulatorsSection(model: model, report: report)
                    XcodeSection(model: model, report: report)
                    StorageSection(model: model, report: report)
                }
                if model.canRemove, let mac = model.listedMac { RemovalSection(model: model, mac: mac) }
            }
            .formStyle(.grouped)
        }
    }
}

/// The Mac's status, whether it takes new jobs and how many at once, the labels of its runners, and its runner
/// services.
@MainActor
private struct OverviewSection: View {
    @Bindable var model: MacPaneModel

    var body: some View {
        Section("Overview") {
            if let connection = model.connection { MacConnectionRows(connection: connection) }
            if let report = model.report {
                HostStatusRows(settings: report)
                Toggle("Take new jobs", isOn: Binding(get: { !report.isPaused }, set: { model.setPaused(!$0) }))
                    .disabled(model.isChangingPause)
                    .accessibilityIdentifier("take-new-jobs")
                if report.isPaused {
                    Text("\(model.mac.subject) is paused. Its runner services stop after the jobs that they run, and its runners stay registered and appear offline on GitHub.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.pauseError { ErrorText(error) }
                TextField("Maximum concurrent jobs", text: $model.poolDraft.capacityInput)
                    .disabled(model.isApplyingPoolConfiguration)
                    .accessibilityIdentifier("execution-limit")
                if let error = model.poolConfigurationError { ErrorText(error) }
                if let error = report.configurationCleanupError { ErrorText(error) }
                TextField("Runner labels", text: $model.runnerLabelsInput, prompt: Text("None"))
                    .disabled(model.isSavingRunnerLabels)
                    .accessibilityIdentifier("runner-labels")
                    .help("Separate multiple labels with commas.")
                if let error = model.runnerLabelsError { ErrorText(error) }
                runners(report)
            }
        }
    }

    /// How many runner services the Mac has in each state, and the runners that need attention.
    @ViewBuilder
    private func runners(_ report: HostSettingsReport) -> some View {
        if report.runners.isEmpty {
            LabeledContent("Runners") {
                Text(report.storageError == nil ? "None" : "Not started because storage needs attention")
            }
        } else {
            LabeledContent("Runners", value: summary(of: report.runners))
        }
        ForEach(report.runners.filter(needsAttention)) { runner in
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(runner.name, value: runner.state.rawValue)
                if runner.state == .individualService {
                    Text("This runner uses its individual service. The host does not start another service for it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = runner.configurationError { ErrorText(error) }
            }
        }
        if let error = report.runnerScanError { ErrorText(error) }
    }

    /// The states of the runners with how many are in each, in the order of the first runner in each.
    private func summary(of runners: [RunnerSettingsRow]) -> String {
        var states: [RunnerServiceState] = []
        for runner in runners where !states.contains(runner.state) { states.append(runner.state) }
        return states.map { state in "\(runners.count { $0.state == state }) \(state.rawValue.lowercased())" }
            .joined(separator: " · ")
    }

    /// Whether a runner is listed by name: its service does not do what the Mac's other settings say.
    private func needsAttention(_ runner: RunnerSettingsRow) -> Bool {
        runner.configurationError != nil || [.failed, .stopped, .individualService].contains(runner.state)
    }
}

/// How long the Mac keeps idle Simulators.
@MainActor
private struct SimulatorsSection: View {
    @Bindable var model: MacPaneModel
    let report: HostSettingsReport

    var body: some View {
        let isApplying = model.isApplyingPoolConfiguration
        Section {
            Picker("Idle Simulators", selection: $model.poolDraft.keepsSimulatorsForever) {
                Text("Remove after an idle period").tag(false)
                Text("Keep indefinitely").tag(true)
            }
            .disabled(isApplying)
            .accessibilityIdentifier("simulator-retention-mode")
            if !model.poolDraft.keepsSimulatorsForever {
                TextField("Idle retention (minutes)", text: $model.poolDraft.simulatorIdleRetentionInput)
                    .disabled(isApplying)
                    .accessibilityIdentifier("simulator-idle-retention")
            }
            if let error = report.simulatorPoolError { ErrorText(error) }
        } header: {
            Text("Simulators")
        } footer: {
            Text("Idle Simulators stay booted for reuse until their retention ends.")
        }
    }
}

/// The Xcode that the Mac's jobs use when they name none.
@MainActor
private struct XcodeSection: View {
    @Bindable var model: MacPaneModel
    let report: HostSettingsReport

    var body: some View {
        Section("Xcode") {
            Picker("Xcode for jobs", selection: $model.selectedXcode) {
                Text("System selection").tag(MacPaneModel.XcodeChoice.ID?.none)
                ForEach(model.xcodeChoices) { xcode in Text(xcode.title).tag(Optional(xcode.id)) }
            }
            .disabled(model.isSavingXcode)
            .accessibilityIdentifier("xcode-for-jobs")
            if let problem = model.savedXcodeProblem { ErrorText(problem) }
            if let error = report.xcodeError { ErrorText(error) }
            if let error = model.xcodeSaveError { ErrorText(error) }
            // A Mac that runs a version without the setting reports none.
            if model.showsBuildService {
                TextField("Build service", text: $model.buildServiceInput, prompt: Text("None"))
                    .disabled(model.isSavingBuildService)
                    .accessibilityIdentifier("build-service")
                if model.canChooseFiles {
                    HStack {
                        Spacer()
                        Button("Choose…") { model.chooseBuildService() }
                            .disabled(model.isSavingBuildService)
                            .accessibilityIdentifier("choose-build-service")
                    }
                }
                if let problem = model.savedBuildServiceProblem { ErrorText(problem) }
                if let error = report.buildServiceError { ErrorText(error) }
                if let error = model.buildServiceSaveError { ErrorText(error) }
            }
        }
    }
}

/// The folder for runner checkouts, build results, and the compiler cache.
@MainActor
private struct StorageSection: View {
    @Bindable var model: MacPaneModel
    let report: HostSettingsReport
    @State private var isConfirmingRestart = false

    var body: some View {
        // A restart would end the host before it saved the values that a save has still to save.
        let isSaving = model.isSaving
        let isRestarting = model.isRestarting
        let canEdit = model.canEditStorageDirectory
        Section("Storage") {
            TextField("Storage folder", text: $model.storageDirectoryInput, prompt: Text("Not chosen"))
                .accessibilityIdentifier("storage-folder")
                .disabled(!canEdit)
            // A panel on this Mac cannot choose a folder of another Mac.
            if model.canChooseFiles {
                HStack {
                    Spacer()
                    Button("Choose…") { model.chooseStorageDirectory() }
                        .disabled(!canEdit)
                        .accessibilityIdentifier("choose-storage-folder")
                }
            }
            Text(report.storageMessage).foregroundStyle(.secondary)
            // A host that launchd did not start is restarted by whoever started it.
            if report.storageChangeIsPending, report.canRestart || isRestarting || isSaving {
                HStack {
                    Spacer()
                    Button(isRestarting ? "Restarting…" : "Restart to Apply…") { isConfirmingRestart = true }
                        .disabled(isRestarting || isSaving || !report.canRestart)
                        .accessibilityIdentifier("restart-host")
                }
            }
            if let error = report.storageError { ErrorText(error) }
            if let error = model.storageSaveError { ErrorText(error) }
            if let error = model.restartError { ErrorText(error) }
        }
        .confirmationDialog("Restart XcodeHomeRunner on \(model.mac.object)?", isPresented: $isConfirmingRestart) {
            Button("Restart", role: .destructive) { model.restart() }
        } message: {
            Text("\(runningJobs) Restarting stops \(model.mac.possessive) runner services and their jobs, then applies the saved folder. Finish other work using runner storage first.")
        }
    }

    /// The Xcode jobs counted at the last read. The count includes jobs that other tools started in the same
    /// execution pool, which a restart leaves running, and a job can have started since.
    private var runningJobs: String {
        let mac = model.mac.object
        return switch report.poolStatus?.activeJobCount {
        case nil: "The Xcode jobs running on \(mac) are unknown."
        case 0?: "No Xcode jobs were running on \(mac) at the last read."
        case 1?: "1 Xcode job was running on \(mac) at the last read."
        case let count?: "\(count) Xcode jobs were running on \(mac) at the last read."
        }
    }
}

/// Ends the pairing with a paired Mac.
@MainActor
private struct RemovalSection: View {
    let model: MacPaneModel
    let mac: ListedMac
    @State private var isConfirming = false

    var body: some View {
        Section {
            HStack {
                Spacer()
                Button(model.isRemoving ? "Removing…" : "Remove Mac…", role: .destructive) { isConfirming = true }
                    .disabled(model.isRemoving)
                    .accessibilityIdentifier("remove-mac")
            }
        } footer: {
            Text("Removing ends the pairing on both Macs. Runner services on \(mac.name) keep running.")
        }
        .confirmationDialog("Remove \(mac.name)?", isPresented: $isConfirming) {
            Button("Remove", role: .destructive) { model.remove() }
        } message: {
            Text(model.removalConsequence)
        }
    }
}
