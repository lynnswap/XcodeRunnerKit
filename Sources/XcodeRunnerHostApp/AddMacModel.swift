import Foundation
import Observation

/// What the Add Mac sheet shows and does while it pairs with a Mac that waits to pair: a Mac for a host to manage, or
/// a host for a dashboard to show.
@MainActor @Observable
final class AddMacModel {
    private let macs: any MacList
    /// Called when the sheet is done, with the Mac that it paired with unless the person cancelled.
    @ObservationIgnored var onFinish: (@MainActor (ListedMac?) -> Void)?
    private var chosenMac: WaitingMac.ID?
    /// The Mac that a pairing connects to, until the Macs show their codes.
    private(set) var connectingMac: WaitingMac?
    private(set) var errorMessage: String?
    @ObservationIgnored private var pairing: Task<Void, Never>?

    /// Sets up this Mac as a runner for the sheet to pair, on a Mac that has no host.
    let thisMac: ThisMacSetup?

    /// - Parameters:
    ///   - macs: The list that the paired Mac joins.
    ///   - thisMac: Sets up this Mac for the sheet to pair, when it can be.
    init(macs: any MacList, thisMac: ThisMacSetup? = nil) {
        self.macs = macs
        self.thisMac = thisMac
    }

    /// What the Mac that pairs does with the Mac that it pairs with.
    var role: PairingRole { macs.role }
    var codeConfirmation: PairedMacs.CodeConfirmation? { macs.codeConfirmation }
    /// Why no Macs can be listed.
    var discoveryMessage: String? { macs.discoveryMessage }
    /// The waiting Macs that run a version of the app that this Mac's version works with.
    var pairableMacs: [WaitingMac] { macs.waitingMacs.filter { $0.mismatch == nil } }

    /// Why each waiting Mac that runs too old a version of the app cannot pair until it is updated.
    var versionMismatches: [String] {
        macs.waitingMacs.compactMap { mac in mac.mismatch?.explanation(of: mac.name, for: macs.pairedWith) }
    }

    /// The Mac to pair with: the one that the person chose while it waits, or else the first one.
    var selection: WaitingMac.ID? {
        get { pairableMacs.contains { $0.id == chosenMac } ? chosenMac : pairableMacs.first?.id }
        set { chosenMac = newValue }
    }

    /// Whether the person chooses a Mac, which they do until a pairing starts.
    var isChoosingMac: Bool { connectingMac == nil && codeConfirmation == nil }

    /// Lists the Macs that wait to pair until `stop()`.
    func start() { macs.discoverPairableMacs() }

    func stop() {
        pairing?.cancel()
        macs.stopDiscoveringPairableMacs()
    }

    /// Pairs with the selected Mac. The pairing finishes after the person confirms the code here and allows the
    /// pairing on that Mac.
    func pair() {
        guard isChoosingMac, let mac = pairableMacs.first(where: { $0.id == selection }) else { return }
        errorMessage = nil
        connectingMac = mac
        pairing = Task {
            do {
                onFinish?(try await macs.pair(with: mac.id))
            } catch is CancellationError {
            } catch {
                errorMessage = "Could not pair with \(mac.name): \(error.localizedDescription)"
            }
            connectingMac = nil
        }
    }

    /// Confirms that the other Mac shows the same code. For this Mac, which the sheet set up, its host is told the
    /// code and allows the pairing if it shows the same one.
    func confirmCode() {
        let confirmation = macs.codeConfirmation
        macs.confirmCode()
        guard let thisMac, let confirmation, confirmation.macName == HostPane.macName else { return }
        Task {
            do {
                try await thisMac.allowPairing(showing: confirmation.code)
            } catch {
                errorMessage = "Could not allow the pairing on this Mac: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        pairing?.cancel()
        onFinish?(nil)
    }
}
