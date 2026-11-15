import SwiftUI

/// This Mac's roles, in its settings: a host, a runner, or both. A Mac that is no host is managed by a host on another
/// Mac, so turning the role off pairs this Mac with that host, and turning it on again ends the pairing.
@MainActor
struct MacRolesSection: View {
    let model: OverviewModel
    let management: HostManagement
    @State private var isConfirmingStop = false

    var body: some View {
        let isHost = model.isHost ?? true
        let isRunner = model.isRunner ?? true
        Section {
            Toggle(isOn: Binding(get: { isHost }, set: setHost)) {
                Text("Host")
                Text("Signs in to GitHub and registers runners, for this Mac and for the Macs that it manages.")
            }
            // A host that manages Macs stays one until they are removed.
            .disabled(isHost && !model.canStopHosting)
            .accessibilityIdentifier("host-role")
            if let manager = management.manager {
                LabeledContent("Managed by", value: manager.name)
                if let mismatch = management.versionMismatches[manager.id] {
                    Text("\(mismatch.explanation(of: manager.name, for: .thisMac)) Until then, \(manager.name) cannot manage this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if let window = management.pairingWindow, window.role == .manager {
                PairingWindowRows(management: management, window: window)
            } else {
                if model.managedMacCount > 0 {
                    Text("This Mac manages \(model.managedMacCount == 1 ? "1 Mac" : "\(model.managedMacCount) Macs"). Remove them to turn this off.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if management.pairingWindow == nil, let message = management.pairingMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = management.errorMessage { ErrorText(error) }
            if let message = model.managedMacsMessage { ErrorText(message) }
            Toggle(isOn: Binding(get: { isRunner }, set: model.setRunner)) {
                Text("Runner")
                Text("Runs jobs on this Mac.")
            }
            .accessibilityIdentifier("runner-role")
            if !isRunner {
                Text("This Mac is paused. Its runner services stop after the jobs that they run, and its runners stay registered and appear offline on GitHub.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.runnerError { ErrorText(error) }
        } header: {
            Text("Roles")
        } footer: {
            Text("A Mac can be both. One that is no host runs the jobs of a host on another Mac on the local network, which pairs with it here. Each Mac keeps the pairing in its Keychain.")
        }
        .confirmationDialog(
            "Stop management by \(management.manager?.name ?? "the host")?", isPresented: $isConfirmingStop
        ) {
            Button("Stop Management", role: .destructive) { model.becomeHost() }
        } message: {
            Text("The host can no longer connect to this Mac, which becomes a host itself. To have that host manage it again, pair the Macs again.")
        }
    }

    private func setHost(_ isHost: Bool) {
        if !isHost {
            model.stopHosting()
        } else if management.manager != nil {
            // Ending a host's management needs a confirmation, and ending a wait does not.
            isConfirmingStop = true
        } else {
            model.becomeHost()
        }
    }
}

/// The dashboards that show this Mac, in its settings.
@MainActor
struct HostDashboardsSection: View {
    let management: HostManagement
    @State private var removing: HostPairing?

    var body: some View {
        Section {
            ForEach(management.dashboards) { dashboard in
                LabeledContent(dashboard.name) {
                    Button("Remove…", role: .destructive) { removing = dashboard }
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
            Text("A Mac that opens XcodeHomeRunner without installing a host can show this Mac and change its settings. It does not register runners or sign in to GitHub.")
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
struct PairingWindowRows: View {
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
            LabeledContent(window.role == .manager ? "Waiting for a host" : "Waiting for a dashboard") {
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
        case .manager: "On the host, choose Add Mac… in Settings and select \(HostPane.macName)."
        case .dashboard: "On the other Mac, open XcodeHomeRunner, choose File > Add Mac > Show a Mac on This Dashboard…, and select \(HostPane.macName)."
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
