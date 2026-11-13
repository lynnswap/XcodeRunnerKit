import SwiftUI

/// Pairs a Mac that waits to pair with this host.
@MainActor
struct AddMacView: View {
    let macs: PairedMacs
    let paired: (PairedMac) -> Void
    let cancel: () -> Void
    @State private var selection: PairedMacs.PairableMac.ID?
    @State private var pairing: (mac: PairedMacs.PairableMac, task: Task<Void, Never>)?
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
        .onChange(of: macs.pairableMacs, initial: true) {
            if selectedMac == nil { selection = macs.pairableMacs.first?.id }
        }
    }

    private var macList: some View {
        Section {
            if macs.pairableMacs.isEmpty {
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
                    ForEach(macs.pairableMacs) { mac in Text(mac.name).tag(Optional(mac.id)) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        } header: {
            Text("Macs Waiting to Pair")
        } footer: {
            Text("On the Mac to add, choose Settings… from the XcodeHomeRunner menu, select that Mac under Runners, then choose Allow Management… to list it here.")
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

    private var selectedMac: PairedMacs.PairableMac? { macs.pairableMacs.first { $0.id == selection } }

    private func pair() {
        guard let mac = selectedMac else { return }
        errorMessage = nil
        let task = Task {
            do {
                paired(try await macs.pair(at: mac.endpoint))
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

/// A Mac that this host manages.
@MainActor
struct PairedMacView: View {
    let model: HostSettingsModel
    let mac: PairedMac
    let navigation: HostWindowNavigation
    @State private var isConfirmingRemoval = false
    @State private var isRemoving = false

    private var macs: PairedMacs { model.managedMacs }

    var body: some View {
        let status = macs.status(of: mac.id)
        let settings = macs.settings[mac.id]
        // Settings from an earlier read may have changed since, so they appear only while the Mac answers.
        let report = status == .online ? settings?.report : nil
        Form {
            Section {
                LabeledContent("Connection") {
                    Label {
                        Text(status.title)
                    } icon: {
                        Image(systemName: status.systemImage).foregroundStyle(status.tint)
                    }
                }
                switch status {
                case .notFound:
                    Text("\(mac.name) appears here while XcodeHomeRunner runs on it and both Macs are on the same local network. If you chose Stop Management on \(mac.name), remove it here.")
                        .font(.callout).foregroundStyle(.secondary)
                case .rejected:
                    Text("\(mac.name) no longer accepts this Mac. Remove it, then pair again.")
                        .font(.callout).foregroundStyle(.secondary)
                case .unreachable(let message): ErrorText(message)
                case .checking, .online: EmptyView()
                }
                if report == nil, let readAt = settings?.readAt {
                    LabeledContent("Settings last read") { Text(readAt, format: .dateTime) }
                }
                if let report { HostStatusRows(settings: report) }
                if let message = macs.message { ErrorText(message) }
            }
            if let settings, let report {
                PairedMacSettingsSections(model: model, mac: mac, settings: settings, report: report)
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
                    if macs.mac(mac.id) == nil { navigation.pane = .mac }
                }
            }
        } message: {
            Text("\(mac.name) stops accepting this Mac as its managing host. To manage it again, pair the Macs again.")
        }
        .task(id: mac.id) { await macs.watchSettings(of: mac.id) }
    }
}

/// A managed Mac's runner services and execution settings, with the controls of the Mac's own window.
@MainActor
private struct PairedMacSettingsSections: View {
    let model: HostSettingsModel
    let mac: PairedMac
    @Bindable var settings: PairedMacSettings
    let report: HostSettingsReport

    var body: some View {
        RunnerServicesSection(settings: report) { Text("Processes on \(mac.name).") }
        XcodeExecutionSection(
            settings: report, draft: $settings.poolDraft, isSaving: settings.isSaving,
            canApply: settings.canApplyPoolConfiguration, saveError: settings.saveError
        ) {
            Task {
                // This Mac registers the Mac's runners, so a changed limit is applied to them here.
                if await model.managedMacs.applyPoolConfiguration(of: mac.id) { await model.github.synchronize() }
            }
        }
        StorageSection(
            settings: report, directory: $settings.storageDirectoryInput, isSaving: settings.isSavingStorage,
            saveError: settings.storageSaveError, choose: nil
        ) {
            Task { await model.managedMacs.saveStorageDirectory(of: mac.id) }
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
            } else if let window = management.pairingWindow {
                if let request = window.request, let code = request.code {
                    LabeledContent("\(request.managerName) asks to manage this Mac") { PairingCode(code) }
                    if request.isAllowed {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to choose Pair on \(request.managerName)…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Allow only if \(request.managerName) shows the same code. A different code means that another device asked.")
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
                        Text("Connecting to \(request.managerName)…").foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Waiting for a managing Mac") {
                        Text(window.expiresAt, style: .timer).monospacedDigit()
                    }
                    Text("On the managing Mac, choose Add Mac… and select \(HostPane.macName).")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { management.cancelPairing() }
                    }
                }
            } else {
                LabeledContent {
                    Button("Allow Management…") { management.allowManagement() }
                        .disabled(!model.canAllowManagement)
                        .accessibilityIdentifier("allow-management")
                } label: {
                    Text(managementDescription)
                }
                if let message = management.pairingMessage {
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

private extension PairedMacs.Status {
    var title: String {
        switch self {
        case .notFound: "Not found on the local network"
        case .checking: "Checking…"
        case .online: "Connected"
        case .rejected: "Pairing no longer applies"
        case .unreachable: "Not responding"
        }
    }

    var systemImage: String {
        switch self {
        case .notFound: "questionmark.circle"
        case .checking: "circle.dotted"
        case .online: "checkmark.circle.fill"
        case .rejected, .unreachable: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .online: .green
        case .unreachable: .orange
        case .rejected: .red
        case .notFound, .checking: .secondary
        }
    }
}

#if DEBUG
/// Asks `management` to pair over the loopback interface, so that previews show both Macs' codes.
@MainActor
func requestPreviewPairing(from macs: PairedMacs, with management: HostManagement) {
    management.allowManagement()
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
    AddMacView(macs: PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, browses: false), paired: { _ in }, cancel: {})
}
#Preview("Add Mac Code", traits: .sizeThatFitsLayout) {
    let macs = PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, browses: false)
    requestPreviewPairing(from: macs, with: HostManagement(store: PreviewSecretStore(), name: "m1pro", advertises: false))
    return AddMacView(macs: macs, paired: { _ in }, cancel: {})
}
#endif
