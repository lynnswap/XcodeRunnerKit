import AppKit
import SwiftUI

struct ErrorText: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
    }
}

/// A Mac's host status and Xcode job counts.
@MainActor
struct HostStatusRows: View {
    let settings: HostSettingsReport

    var body: some View {
        LabeledContent("Status") {
            Label {
                Text(settings.stateTitle)
            } icon: {
                Image(systemName: settings.stateSymbol).foregroundStyle(Color(nsColor: settings.stateTint))
            }
        }
        LabeledContent("Xcode jobs") { Text(settings.jobSummary).monospacedDigit() }
        Text(settings.admissionMessage).font(.callout).foregroundStyle(.secondary)
        if let error = settings.storageError { ErrorText(error) }
        if let error = settings.poolError { ErrorText(error) }
    }
}

@MainActor
extension HostSettingsReport {
    // A paused Mac runs as its person chose, so it does not look like a host that needs attention.

    /// The host's state, as the panes and the sidebar name it.
    var stateTitle: String { showsPaused ? "Paused" : hostState.rawValue }
    var stateSymbol: String { showsPaused ? "pause.circle.fill" : hostState.systemImage }
    var stateTint: NSColor { showsPaused ? .secondaryLabelColor : hostState.tint }


}

private extension HostState {
    var systemImage: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .starting, .preparingStorage: "circle.dotted"
        case .waitingForStorage: "clock"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        // A state of a newer version.
        default: "circle"
        }
    }

    var tint: NSColor {
        switch self {
        case .running: .systemGreen
        case .waitingForStorage: .systemOrange
        case .needsAttention: .systemRed
        default: .secondaryLabelColor
        }
    }
}

/// Whether a paired Mac answers and, while it does not, when its settings were last read.
@MainActor
struct MacConnectionRows: View {
    let connection: MacConnection

    var body: some View {
        LabeledContent("Connection") {
            Label {
                Text(connection.status.title)
            } icon: {
                Image(systemName: connection.status.systemImage).foregroundStyle(Color(nsColor: connection.status.tint))
            }
        }
        switch connection.status {
        case .notFound:
            Text("\(connection.macName) appears here while XcodeHomeRunner runs on it and \(sameNetwork). \(endedElsewhere)")
                .font(.callout).foregroundStyle(.secondary)
        case .rejected:
            Text("\(connection.macName) no longer accepts \(connection.pairedWith.object). Remove it, then pair again.")
                .font(.callout).foregroundStyle(.secondary)
        case .incompatible(let mismatch):
            Text("\(mismatch.explanation(of: connection.macName, for: connection.pairedWith)) The pairing is kept, and the Macs connect again after the update.")
                .font(.callout).foregroundStyle(.secondary)
        case .unreachable(let message): ErrorText(message)
        case .checking, .online: EmptyView()
        }
        if let readAt = connection.settingsReadAt {
            LabeledContent("Settings last read") { Text(readAt, format: .dateTime) }
        }
        if let message = connection.message { ErrorText(message) }
    }

    /// Where the Mac has to be for the Mac that is paired with it to find it.
    private var sameNetwork: String {
        connection.pairedWith.name.map { "it is on the same local network as \($0)" } ?? "both Macs are on the same local network"
    }

    /// What to do here when the pairing was ended on the other Mac.
    private var endedElsewhere: String {
        switch connection.role {
        case .manager: "If you chose Stop Management on \(connection.macName), remove it here."
        case .dashboard: "If you removed this Mac under Dashboards on \(connection.macName), remove it here."
        }
    }
}

extension PairedMacs.Status {
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

    var tint: NSColor {
        switch self {
        case .online: .systemGreen
        case .incompatible, .unreachable: .systemOrange
        case .rejected: .systemRed
        case .notFound, .checking: .secondaryLabelColor
        }
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
