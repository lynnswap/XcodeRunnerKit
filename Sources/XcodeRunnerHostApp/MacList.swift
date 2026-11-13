import Foundation
import Observation

/// A Mac in a list of paired Macs.
struct ListedMac: Codable, Equatable, Identifiable, Sendable {
    let id: HostPairing.ID
    let name: String
}

/// A Mac that waits to pair.
struct WaitingMac: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// Set when the Mac runs another version of the app than the Mac that would pair with it, so they cannot pair.
    var mismatch: VersionMismatch?
}

/// The Macs that a window lists, shows, and changes: the Macs that this Mac paired with, or the Macs that a host
/// manages, which a dashboard reaches through that host.
@MainActor
protocol MacList: AnyObject, Observable {
    /// What the Mac that is paired with these Macs does with them.
    var role: PairingRole { get }
    /// The Mac that is paired with these Macs: this Mac, or the host that a dashboard reaches them through.
    var pairedWith: MacReference { get }
    var listedMacs: [ListedMac] { get }
    var message: String? { get }
    func status(of id: HostPairing.ID) -> PairedMacs.Status
    func settings(of id: HostPairing.ID) -> PairedMacSettings?
    /// Reads a Mac's settings every few seconds until the task is cancelled.
    func watchSettings(of id: HostPairing.ID) async
    /// - Returns: Whether the Mac saved a different job limit.
    @discardableResult func applyPoolConfiguration(of id: HostPairing.ID) async -> Bool
    func saveStorageDirectory(of id: HostPairing.ID) async
    /// Restarts a Mac's host, which applies its saved storage folder.
    func restart(_ id: HostPairing.ID) async
    /// Ends the pairing with a Mac.
    func remove(_ id: HostPairing.ID) async

    var waitingMacs: [WaitingMac] { get }
    var discoveryMessage: String? { get }
    var codeConfirmation: PairedMacs.CodeConfirmation? { get }
    /// Lists Macs that wait to pair until `stopDiscoveringPairableMacs()`.
    func discoverPairableMacs()
    func stopDiscoveringPairableMacs()
    /// Pairs with a waiting Mac. The pairing finishes after the person confirms `codeConfirmation` with
    /// `confirmCode()` and allows the pairing on the Mac.
    func pair(with id: WaitingMac.ID) async throws -> ListedMac
    func confirmCode()
}
