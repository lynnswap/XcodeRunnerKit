import Foundation
import XcodeRunnerHostSupport

/// What a command asks of this Mac's pairings, as the Management and Dashboards sections of its window do.
enum HostPairingRequest: Codable, Sendable {
    case read
    /// Waits five minutes for a Mac to pair in this role.
    case allow(PairingRole)
    /// Allows the Mac that asks to pair if the code that it shows is `code`, and refuses it otherwise.
    case confirm(code: String)
    case refuse
    /// Stops waiting for a Mac to pair.
    case cancel
    case removeDashboard(HostPairing.ID)
    case stopManagement
}

/// This Mac's pairings and the Mac that asks to pair, without the pairings' keys.
struct HostPairingReport: Codable, Equatable, Sendable {
    struct Mac: Codable, Equatable, Sendable {
        let id: UUID
        let name: String

        init(_ pairing: HostPairing) {
            id = pairing.id
            name = pairing.name
        }
    }

    /// The wait for a Mac to pair, and the Mac that asks.
    struct Window: Codable, Equatable, Sendable {
        /// Tells this wait from a later one.
        let id: UUID
        let role: PairingRole
        let expiresAt: Date
        let requesterName: String?
        /// The code that both Macs show once they exchanged keys. The Macs pair once each was told the other's code.
        let code: String?
        /// Whether this Mac allowed the request and waits for the other Mac to allow it too.
        let isAllowed: Bool
    }

    let manager: Mac?
    let dashboards: [Mac]
    let window: Window?
    /// Why the last wait ended without a pairing.
    let message: String?
    let errorMessage: String?

    @MainActor init(_ management: HostManagement) {
        manager = management.manager.map(Mac.init)
        dashboards = management.dashboards.map(Mac.init)
        window = management.pairingWindow.map {
            Window(
                id: $0.id, role: $0.role, expiresAt: $0.expiresAt, requesterName: $0.request?.requesterName, code: $0.request?.code,
                isAllowed: $0.request?.isAllowed ?? false
            )
        }
        message = management.pairingMessage
        errorMessage = management.errorMessage
    }
}

extension HostSettingsModel {
    /// Does what a command asks of this Mac's pairings, under the conditions of the window's buttons.
    func answer(_ request: HostPairingRequest) throws(HostSettingsError) -> HostPairingReport {
        switch request {
        case .read:
            break
        case .allow(let role):
            guard management.pairingWindow == nil else {
                throw HostSettingsError("\(HostPane.macName) already waits for a Mac to pair. Cancel that wait first.")
            }
            switch role {
            case .manager:
                guard management.manager == nil else {
                    throw HostSettingsError("\(HostPane.macName) is managed by \(management.manager?.name ?? "another Mac"). Stop that management first.")
                }
                guard canAllowManagement else {
                    throw HostSettingsError("\(HostPane.macName) manages other Macs. Remove them to let another Mac manage this one.")
                }
                management.allowManagement()
            case .dashboard:
                management.allowDashboard()
            }
        case .confirm(let code):
            guard let asking = management.pairingWindow?.request, let shown = asking.code else {
                throw HostSettingsError("No Mac asks to pair with \(HostPane.macName), or the Macs have not exchanged keys yet.")
            }
            guard shown == code else {
                // A code that differs means the request did not come from the Mac that showed `code`.
                management.refusePairing()
                throw HostSettingsError(
                    "\(asking.requesterName) shows the code \(shown) here, not \(code). The request was refused, and \(HostPane.macName) stopped waiting."
                )
            }
            management.allowPairing()
        case .refuse:
            guard management.pairingWindow?.request != nil else {
                throw HostSettingsError("No Mac asks to pair with \(HostPane.macName).")
            }
            management.refusePairing()
        case .cancel:
            management.cancelPairing()
        case .removeDashboard(let id):
            guard management.dashboards.contains(where: { $0.id == id }) else {
                throw HostSettingsError("\(HostPane.macName) is not paired with that dashboard.")
            }
            management.removeDashboard(id)
            // The pairing stays, and the dashboard still connects, when the Keychain did not take the change.
            guard !management.dashboards.contains(where: { $0.id == id }) else {
                throw HostSettingsError(management.errorMessage ?? "Could not remove the pairing.")
            }
        case .stopManagement:
            guard management.manager != nil else {
                throw HostSettingsError("\(HostPane.macName) is not managed by another Mac.")
            }
            management.stopManagement()
            guard management.manager == nil else {
                throw HostSettingsError(management.errorMessage ?? "Could not remove the pairing.")
            }
        }
        return HostPairingReport(management)
    }
}
