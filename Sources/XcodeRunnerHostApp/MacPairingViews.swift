import SwiftUI

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

/// This Mac's pairing with a managing host, in the Mac's settings.
@MainActor
struct HostManagementSection: View {
    let model: MacPaneModel
    let management: HostManagement
    @State private var isConfirmingStop = false

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
            if let message = model.managedMacsMessage { ErrorText(message) }
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
        let count = model.managedMacCount
        if count > 0 { return "This Mac manages \(count == 1 ? "1 Mac" : "\(count) Macs"). Remove them to let another Mac manage this one." }
        return "Not managed by another Mac"
    }
}

/// The dashboards that show this Mac, in the Mac's settings.
@MainActor
struct HostDashboardsSection: View {
    let management: HostManagement
    @State private var removing: HostPairing?

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

#endif
