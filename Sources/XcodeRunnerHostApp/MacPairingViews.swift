import SwiftUI

/// Pairs with a Mac that waits to pair: a Mac for a host to manage, or a host for this dashboard to show.
@MainActor
struct AddMacView<Macs: MacList>: View {
    let macs: Macs
    let paired: (ListedMac) -> Void
    let cancel: () -> Void
    @State private var selection: WaitingMac.ID?
    @State private var pairing: (mac: WaitingMac, task: Task<Void, Never>)?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let confirmation = macs.codeConfirmation {
                    codeSection(confirmation)
                } else if let pairing {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Connecting to \(pairing.mac.name)…").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    macList
                }
                if let errorMessage {
                    Section { ErrorText(errorMessage) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    pairing?.task.cancel()
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                if let confirmation = macs.codeConfirmation, !confirmation.isConfirmed {
                    Button("Pair") { macs.confirmCode() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("confirm-pairing-code")
                } else if pairing == nil, macs.codeConfirmation == nil {
                    Button("Continue") { pair() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedMac == nil)
                        .accessibilityIdentifier("pair-mac")
                }
            }
            .padding()
        }
        .frame(width: 440, height: 400)
        .onAppear { macs.discoverPairableMacs() }
        .onDisappear {
            pairing?.task.cancel()
            macs.stopDiscoveringPairableMacs()
        }
        .onChange(of: macs.waitingMacs, initial: true) {
            if selectedMac == nil { selection = pairableMacs.first?.id }
        }
    }

    private var macList: some View {
        Section {
            if pairableMacs.isEmpty {
                if let message = macs.discoveryMessage {
                    ErrorText(message)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs…").foregroundStyle(.secondary)
                    }
                }
            } else {
                Picker("Mac", selection: $selection) {
                    ForEach(pairableMacs) { mac in Text(mac.name).tag(Optional(mac.id)) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            // A Mac that runs another version waits too, and cannot pair until both run the same one.
            ForEach(macs.waitingMacs.filter { $0.mismatch != nil }) { mac in
                if let mismatch = mac.mismatch {
                    Text(mismatch.explanation(of: mac.name, for: macs.pairedWith)).font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Macs Waiting to Pair")
        } footer: {
            switch macs.role {
            case .manager:
                Text("On the Mac to add, choose Settings… from the XcodeHomeRunner menu, select that Mac under Runners, then choose Allow Management… to list it here.")
            case .dashboard:
                Text("On the Mac to show, choose Settings… from the XcodeHomeRunner menu, select that Mac under Runners, then choose Allow Dashboard… to list it here.")
            }
        }
    }

    private func codeSection(_ confirmation: PairedMacs.CodeConfirmation) -> some View {
        Section {
            LabeledContent("Code") { PairingCode(confirmation.code) }
            if confirmation.isConfirmed {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to choose Allow on \(confirmation.macName)…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Pair with \(confirmation.macName)")
        } footer: {
            Text("Choose Pair only if \(confirmation.macName) shows the same code, then choose Allow on \(confirmation.macName). A different code means that another device answered.")
        }
    }

    /// The waiting Macs that run the same version of the app.
    private var pairableMacs: [WaitingMac] { macs.waitingMacs.filter { $0.mismatch == nil } }
    private var selectedMac: WaitingMac? { pairableMacs.first { $0.id == selection } }

    private func pair() {
        guard let mac = selectedMac else { return }
        errorMessage = nil
        let task = Task {
            do {
                paired(try await macs.pair(with: mac.id))
            } catch is CancellationError {
            } catch {
                errorMessage = "Could not pair with \(mac.name): \(error.localizedDescription)"
            }
            pairing = nil
        }
        pairing = (mac, task)
    }
}

/// A pairing code, grouped for reading aloud and comparing.
struct PairingCode: View {
    let code: String

    init(_ code: String) { self.code = code }

    var body: some View {
        Text("\(code.prefix(3)) \(code.suffix(3))")
            .font(.title2.monospacedDigit())
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .accessibilityIdentifier("pairing-code")
    }
}

/// A Mac in a list of paired Macs: one that a host manages, or a host that this dashboard shows.
@MainActor
struct PairedMacView<Macs: MacList>: View {
    let macs: Macs
    let mac: ListedMac
    /// Called after the Mac saved a different job limit or different runner labels. A managing host then updates
    /// the Mac's runners.
    let registrationsChanged: () async -> Void
    /// Called after the pairing ended and the Mac left the list.
    let removed: () -> Void
    @State private var isConfirmingRemoval = false
    @State private var isRemoving = false

    var body: some View {
        let settings = macs.settings(of: mac.id)
        // Settings from an earlier read may have changed since, so they appear only while the Mac answers.
        let report = macs.status(of: mac.id) == .online ? settings?.report : nil
        Form {
            Section {
                PairedMacConnectionRows(macs: macs, mac: mac)
                if let report { HostStatusRows(settings: report) }
                if let message = macs.message { ErrorText(message) }
            }
            if let settings, let report {
                PairedMacSettingsSections(macs: macs, mac: mac, settings: settings, report: report, registrationsChanged: registrationsChanged)
            }
            Section {
                HStack {
                    Spacer()
                    Button(isRemoving ? "Removing…" : "Remove Mac…", role: .destructive) { isConfirmingRemoval = true }
                        .disabled(isRemoving)
                        .accessibilityIdentifier("remove-mac")
                }
            } footer: {
                Text("Removing ends the pairing on both Macs. Runner services on \(mac.name) keep running.")
            }
        }
        .confirmationDialog("Remove \(mac.name)?", isPresented: $isConfirmingRemoval) {
            Button("Remove", role: .destructive) {
                isRemoving = true
                Task {
                    await macs.remove(mac.id)
                    isRemoving = false
                    if !macs.listedMacs.contains(mac) { removed() }
                }
            }
        } message: {
            switch macs.role {
            case .manager:
                Text("\(mac.name) stops accepting \(macs.pairedWith.object) as its managing host. To manage it again, pair the Macs again.")
            case .dashboard:
                Text("\(mac.name) stops accepting this Mac as a dashboard. To show it again, pair the Macs again.")
            }
        }
        .task(id: mac.id) { await macs.watchSettings(of: mac.id) }
    }

}

/// Whether a paired Mac answers and, while it does not, when its settings were last read.
@MainActor
struct PairedMacConnectionRows<Macs: MacList>: View {
    let macs: Macs
    let mac: ListedMac

    var body: some View {
        let status = macs.status(of: mac.id)
        LabeledContent("Connection") {
            Label {
                Text(status.title)
            } icon: {
                Image(systemName: status.systemImage).foregroundStyle(status.tint)
            }
        }
        switch status {
        case .notFound:
            Text("\(mac.name) appears here while XcodeHomeRunner runs on it and \(sameNetwork). \(endedElsewhere)")
                .font(.callout).foregroundStyle(.secondary)
        case .rejected:
            Text("\(mac.name) no longer accepts \(macs.pairedWith.object). Remove it, then pair again.")
                .font(.callout).foregroundStyle(.secondary)
        case .incompatible(let mismatch):
            Text("\(mismatch.explanation(of: mac.name, for: macs.pairedWith)) The pairing is kept, and the Macs connect again after the update.")
                .font(.callout).foregroundStyle(.secondary)
        case .unreachable(let message): ErrorText(message)
        case .checking, .online: EmptyView()
        }
        if status != .online, let readAt = macs.settings(of: mac.id)?.readAt {
            LabeledContent("Settings last read") { Text(readAt, format: .dateTime) }
        }
    }

    /// Where the Mac has to be for the Mac that is paired with it to find it.
    private var sameNetwork: String {
        macs.pairedWith.name.map { "it is on the same local network as \($0)" } ?? "both Macs are on the same local network"
    }

    /// What to do here when the pairing was ended on the other Mac.
    private var endedElsewhere: String {
        switch macs.role {
        case .manager: "If you chose Stop Management on \(mac.name), remove it here."
        case .dashboard: "If you removed this Mac under Dashboards on \(mac.name), remove it here."
        }
    }
}

/// A paired Mac's runner services and execution settings, with the controls of the Mac's own window.
@MainActor
private struct PairedMacSettingsSections<Macs: MacList>: View {
    let macs: Macs
    let mac: ListedMac
    @Bindable var settings: PairedMacSettings
    let report: HostSettingsReport
    let registrationsChanged: () async -> Void

    var body: some View {
        RunnerServicesSection(
            settings: report, mac: MacReference(name: mac.name), isChangingPause: settings.isChangingPause,
            pauseError: settings.pauseError, setPaused: { isPaused in Task { await macs.setPaused(isPaused, of: mac.id) } }
        ) {
            Text("Processes on \(mac.name).")
        }
        RunnerLabelsSection(
            labels: $settings.runnerLabelsInput, isSaving: settings.isSavingRunnerLabels,
            saveError: settings.runnerLabelsError, mac: MacReference(name: mac.name)
        ) {
            Task {
                if await macs.saveRunnerLabels(of: mac.id) { await registrationsChanged() }
            }
        }
        XcodeExecutionSection(
            settings: report, draft: $settings.poolDraft, isSaving: settings.isSaving,
            canApply: settings.canApplyPoolConfiguration, saveError: settings.saveError
        ) {
            Task {
                if await macs.applyPoolConfiguration(of: mac.id) { await registrationsChanged() }
            }
        }
        XcodeSection(
            settings: report, selection: $settings.xcodeSelectionInput, isSaving: settings.isSavingXcode,
            saveError: settings.xcodeSaveError, mac: MacReference(name: mac.name)
        ) {
            Task { await macs.saveXcodeSelection(of: mac.id) }
        }
        StorageSection(
            settings: report, directory: $settings.storageDirectoryInput, isSaving: settings.isSavingStorage,
            saveError: settings.storageSaveError, mac: MacReference(name: mac.name), isRestarting: settings.isRestarting,
            restartError: settings.restartError, choose: nil, restart: { Task { await macs.restart(mac.id) } }
        ) {
            Task { await macs.saveStorageDirectory(of: mac.id) }
        }
    }
}

/// This Mac's pairing with a managing host, in the Mac's settings.
@MainActor
struct HostManagementSection: View {
    let model: HostSettingsModel
    @State private var isConfirmingStop = false

    private var management: HostManagement { model.management }

    var body: some View {
        Section {
            if let manager = management.manager {
                LabeledContent("Managed by") {
                    HStack {
                        Text(manager.name)
                        Button("Stop Management…") { isConfirmingStop = true }
                            .accessibilityIdentifier("stop-management")
                    }
                }
                if let mismatch = management.versionMismatches[manager.id] {
                    Text("\(mismatch.explanation(of: manager.name, for: .thisMac)) Until then, \(manager.name) cannot manage this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if let window = management.pairingWindow, window.role == .manager {
                PairingWindowRows(management: management, window: window)
            } else {
                LabeledContent {
                    Button("Allow Management…") { management.allowManagement() }
                        .disabled(!model.canAllowManagement || management.pairingWindow != nil)
                        .accessibilityIdentifier("allow-management")
                } label: {
                    Text(managementDescription)
                }
                if management.pairingWindow == nil, let message = management.pairingMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = management.errorMessage { ErrorText(error) }
            if let message = model.managedMacs.message { ErrorText(message) }
        } header: {
            Text("Management")
        } footer: {
            Text("Another Mac on the local network can manage this Mac's runners after you pair them here. Each Mac keeps the pairing in its Keychain.")
        }
        .confirmationDialog(
            "Stop management by \(management.manager?.name ?? "the managing Mac")?", isPresented: $isConfirmingStop
        ) {
            Button("Stop Management", role: .destructive) { management.stopManagement() }
        } message: {
            Text("The managing Mac can no longer connect to this Mac. To manage it again, pair the Macs again.")
        }
    }

    private var managementDescription: String {
        let count = model.managedMacs.macs.count
        if count > 0 { return "This Mac manages \(count == 1 ? "1 Mac" : "\(count) Macs"). Remove them to let another Mac manage this one." }
        return "Not managed by another Mac"
    }
}

/// The dashboards that show this Mac, in the Mac's settings.
@MainActor
struct HostDashboardsSection: View {
    let model: HostSettingsModel
    @State private var removing: HostPairing?

    private var management: HostManagement { model.management }

    var body: some View {
        Section {
            ForEach(management.dashboards) { dashboard in
                LabeledContent(dashboard.name) {
                    Button("Remove…") { removing = dashboard }
                        .accessibilityIdentifier("remove-dashboard")
                }
                if let mismatch = management.versionMismatches[dashboard.id] {
                    Text("\(mismatch.explanation(of: dashboard.name, for: .thisMac)) Until then, \(dashboard.name) cannot show this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let window = management.pairingWindow, window.role == .dashboard {
                PairingWindowRows(management: management, window: window)
            } else {
                LabeledContent {
                    Button("Allow Dashboard…") { management.allowDashboard() }
                        .disabled(management.pairingWindow != nil)
                        .accessibilityIdentifier("allow-dashboard")
                } label: {
                    Text(management.dashboards.isEmpty ? "Not shown on another Mac" : "Add another dashboard")
                }
            }
        } header: {
            Text("Dashboards")
        } footer: {
            Text("A Mac that opens XcodeHomeRunner without installing a host can show this Mac and change the settings below. It does not register runners or sign in to GitHub.")
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "the dashboard")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { dashboard in
            Button("Remove", role: .destructive) { management.removeDashboard(dashboard.id) }
        } message: { dashboard in
            Text("\(dashboard.name) can no longer connect to this Mac. To show this Mac there again, pair the Macs again.")
        }
    }
}

/// The Mac that asks to pair while this Mac waits, for a managing Mac or a dashboard.
@MainActor
private struct PairingWindowRows: View {
    let management: HostManagement
    let window: HostManagement.PairingWindow

    var body: some View {
        if let request = window.request, let code = request.code {
            LabeledContent(question(from: request.requesterName)) { PairingCode(code) }
            if request.isAllowed {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to choose Pair on \(request.requesterName)…").foregroundStyle(.secondary)
                }
            } else {
                Text("Allow only if \(request.requesterName) shows the same code. A different code means that another device asked.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Don't Allow") { management.refusePairing() }
                        .accessibilityIdentifier("refuse-pairing")
                    Button("Allow") { management.allowPairing() }
                        .accessibilityIdentifier("allow-pairing")
                }
            }
        } else if let request = window.request {
            HStack {
                ProgressView().controlSize(.small)
                Text("Connecting to \(request.requesterName)…").foregroundStyle(.secondary)
            }
        } else {
            LabeledContent(window.role == .manager ? "Waiting for a managing Mac" : "Waiting for a dashboard") {
                Text(window.expiresAt, style: .timer).monospacedDigit()
            }
            Text(instruction).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { management.cancelPairing() }
            }
        }
    }

    private func question(from requesterName: String) -> String {
        switch window.role {
        case .manager: "\(requesterName) asks to manage this Mac"
        case .dashboard: "\(requesterName) asks to show this Mac"
        }
    }

    private var instruction: String {
        switch window.role {
        case .manager: "On the managing Mac, choose Add Mac… and select \(HostPane.macName)."
        case .dashboard: "On the other Mac, open XcodeHomeRunner, choose Add Mac… > Show a Mac on This Dashboard…, and select \(HostPane.macName)."
        }
    }
}

extension VersionMismatch {
    /// Which Mac runs the older version of the app, and so has to be updated.
    ///
    /// - Parameters:
    ///   - macName: The Mac that this mismatch describes.
    ///   - other: The Mac that connects to it or lists it.
    func explanation(of macName: String, for other: MacReference) -> String {
        switch self {
        case .older: "\(macName) runs an older version of XcodeHomeRunner. Update it to the version on \(other.object)."
        case .newer: "\(macName) runs a newer version of XcodeHomeRunner. Update \(other.object) to that version."
        }
    }
}

private extension PairedMacs.Status {
    var title: String {
        switch self {
        case .notFound: "Not found on the local network"
        case .checking: "Checking…"
        case .online: "Connected"
        case .rejected: "Pairing no longer applies"
        case .incompatible: "Runs another version"
        case .unreachable: "Not responding"
        }
    }

    var systemImage: String {
        switch self {
        case .notFound: "questionmark.circle"
        case .checking: "circle.dotted"
        case .online: "checkmark.circle.fill"
        case .rejected, .incompatible, .unreachable: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .online: .green
        case .incompatible, .unreachable: .orange
        case .rejected: .red
        case .notFound, .checking: .secondary
        }
    }
}

#if DEBUG
/// Asks `management` to pair over the loopback interface, so that previews show both Macs' codes.
@MainActor
func requestPreviewPairing(from macs: PairedMacs, with management: HostManagement) {
    switch macs.role {
    case .manager: management.allowManagement()
    case .dashboard: management.allowDashboard()
    }
    Task {
        // The preview shows the request while both Macs wait, and shows nothing if it fails.
        do {
            while management.pairingWindow?.port == nil { try await Task.sleep(for: .milliseconds(10)) }
            guard let port = management.pairingWindow?.port else { return }
            try await macs.pair(at: .hostPort(host: "127.0.0.1", port: port))
        } catch {}
    }
}

#Preview("Add Mac", traits: .sizeThatFitsLayout) {
    AddMacView(
        macs: PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .manager, browses: false),
        paired: { _ in }, cancel: {}
    )
}
#Preview("Add Mac Code", traits: .sizeThatFitsLayout) {
    let macs = PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .manager, browses: false)
    requestPreviewPairing(from: macs, with: HostManagement(store: PreviewSecretStore(), name: "m1pro", advertises: false))
    return AddMacView(macs: macs, paired: { _ in }, cancel: {})
}
#endif
