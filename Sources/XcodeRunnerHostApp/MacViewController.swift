import AppKit
import SwiftUI

/// A Mac's pane: its runner services and execution settings.
@MainActor
final class MacViewController: NSHostingController<MacPaneView> {
    init(model: MacPaneModel) {
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
                if let connection = model.connection {
                    Section {
                        MacConnectionRows(connection: connection)
                        if let report = model.report { HostStatusRows(settings: report) }
                    }
                }
                if let report = model.report {
                    RunnerServicesSection(model: model, report: report)
                    RunnerLabelsSection(model: model)
                    XcodeExecutionSection(model: model, report: report)
                    XcodeSection(model: model, report: report)
                    StorageSection(model: model, report: report)
                }
                if model.canRemove, let mac = model.listedMac { RemovalSection(model: model, mac: mac) }
            }
            .formStyle(.grouped)
        }
    }
}

/// Whether the Mac takes new jobs, and its runner services.
@MainActor
private struct RunnerServicesSection: View {
    let model: MacPaneModel
    let report: HostSettingsReport

    var body: some View {
        Section {
            Toggle("Take new jobs", isOn: Binding(get: { !report.isPaused }, set: { model.setPaused(!$0) }))
                .disabled(model.isChangingPause)
                .accessibilityIdentifier("take-new-jobs")
            if report.isPaused {
                Text("\(model.mac.subject) is paused. Its runner services stop after the jobs that they run, and its runners stay registered and appear offline on GitHub.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.pauseError { ErrorText(error) }
            if report.runners.isEmpty {
                Text(report.storageError == nil ? "No runners have opted in to this host." : "Runner services have not started because storage needs attention.")
                    .foregroundStyle(.secondary)
            }
            ForEach(report.runners) { runner in
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
        } header: {
            Text("Runner Services")
        } footer: {
            if let name = model.mac.name {
                Text("Processes on \(name).")
            } else {
                Text("Processes on this Mac. Overview shows each repository's connection and job counts from GitHub.")
            }
        }
    }
}

/// The labels that a workflow chooses the Mac with.
@MainActor
private struct RunnerLabelsSection: View {
    @Bindable var model: MacPaneModel

    var body: some View {
        Section {
            TextField("Labels", text: $model.runnerLabelsInput, prompt: Text("None"))
                .disabled(model.isSavingRunnerLabels)
                .accessibilityIdentifier("runner-labels")
            HStack {
                Spacer()
                Button(model.isSavingRunnerLabels ? "Saving…" : "Save") { model.saveRunnerLabels() }
                    .disabled(!model.canSaveRunnerLabels)
                    .accessibilityIdentifier("save-runner-labels")
            }
            if let error = model.runnerLabelsError { ErrorText(error) }
        } header: {
            Text("Runner Labels")
        } footer: {
            Text("Runners on \(model.mac.object) get these labels besides xcode-runnerkit. Separate labels with commas. A workflow chooses \(model.mac.object) with one of them in runs-on.")
        }
    }
}

/// The Mac's job limit and how long it keeps idle Simulators.
@MainActor
private struct XcodeExecutionSection: View {
    @Bindable var model: MacPaneModel
    let report: HostSettingsReport

    var body: some View {
        let isApplying = model.isApplyingPoolConfiguration
        Section {
            TextField("Maximum concurrent jobs", text: $model.poolDraft.capacityInput)
                .disabled(isApplying)
                .accessibilityIdentifier("execution-limit")
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
            HStack {
                Spacer()
                Button(isApplying ? "Applying…" : "Apply") { model.applyPoolConfiguration() }
                    .disabled(!model.canApplyPoolConfiguration)
                    .accessibilityIdentifier("apply-pool-configuration")
            }
            if let error = report.poolError { ErrorText(error) }
            if let error = model.poolConfigurationError { ErrorText(error) }
            if let error = report.configurationCleanupError { ErrorText(error) }
            if let error = report.simulatorPoolError { ErrorText(error) }
        } header: {
            Text("Xcode Execution")
        } footer: {
            Text("The limit is shared by all repositories, and each repository registers that many runners. Running jobs finish before a lower limit applies. Idle Simulators stay booted for reuse until their retention ends.")
        }
    }
}

/// The Xcode that the Mac's jobs use when they name none.
@MainActor
private struct XcodeSection: View {
    @Bindable var model: MacPaneModel
    let report: HostSettingsReport

    var body: some View {
        Section {
            Picker("Xcode for jobs", selection: $model.selectedXcode) {
                Text("System selection").tag(MacPaneModel.XcodeChoice.ID?.none)
                ForEach(model.xcodeChoices) { xcode in Text(xcode.title).tag(Optional(xcode.id)) }
            }
            .disabled(model.isSavingXcode)
            .accessibilityIdentifier("xcode-for-jobs")
            HStack {
                Spacer()
                Button(model.isSavingXcode ? "Saving…" : "Save") { model.saveXcodeSelection() }
                    .disabled(!model.canSaveXcodeSelection)
                    .accessibilityIdentifier("save-xcode")
            }
            if let problem = model.savedXcodeProblem { ErrorText(problem) }
            if let error = report.xcodeError { ErrorText(error) }
            if let error = model.xcodeSaveError { ErrorText(error) }
        } header: {
            Text("Xcode")
        } footer: {
            Text("Jobs on \(model.mac.object) use this Xcode unless their workflow passes --developer-directory or DEVELOPER_DIR. With System selection, they use the Xcode that xcode-select names.")
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
        let isSaving = model.isSavingStorage
        let isRestarting = model.isRestarting
        let canEdit = model.canEditStorageDirectory
        Section {
            TextField("Storage folder", text: $model.storageDirectoryInput, prompt: Text("Not chosen"))
                .accessibilityIdentifier("storage-folder")
                .disabled(!canEdit)
            HStack {
                Spacer()
                // A panel on this Mac cannot choose a folder of another Mac.
                if model.canChooseStorageDirectory {
                    Button("Choose…") { model.chooseStorageDirectory() }
                        .disabled(!canEdit)
                        .accessibilityIdentifier("choose-storage-folder")
                }
                Button(isSaving ? "Saving…" : "Save") { model.saveStorageDirectory() }
                    .disabled(!model.canSaveStorageDirectory)
                    .accessibilityIdentifier("save-storage-folder")
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
        } header: {
            Text("Storage")
        } footer: {
            Text("A changed folder is applied before runners start on the next launch. Existing data is copied and its original files are kept. Stop other tools that use these files before restarting the host.")
        }
        .confirmationDialog("Restart XcodeHomeRunner on \(model.mac.object)?", isPresented: $isConfirmingRestart) {
            Button("Restart", role: .destructive) { model.restart() }
        } message: {
            Text("\(runningJobs) Restarting stops \(model.mac.possessive) runner services until the host has started again, with the jobs that they run, and the saved storage folder is applied then.")
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
