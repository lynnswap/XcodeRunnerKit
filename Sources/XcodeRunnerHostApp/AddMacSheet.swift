import AppKit
import Observation
import SwiftUI

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

    /// - Parameter macs: The list that the paired Mac joins.
    init(macs: any MacList) {
        self.macs = macs
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

    /// Confirms that the other Mac shows the same code.
    func confirmCode() { macs.confirmCode() }

    func cancel() {
        pairing?.cancel()
        onFinish?(nil)
    }
}

/// The sheet that pairs with a Mac.
@MainActor
final class AddMacViewController: NSHostingController<AddMacView> {
    init(model: AddMacModel) {
        super.init(rootView: AddMacView(model: model))
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
struct AddMacView: View {
    @Bindable var model: AddMacModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let confirmation = model.codeConfirmation {
                    codeSection(confirmation)
                } else if let mac = model.connectingMac {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Connecting to \(mac.name)…").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    macList
                }
                if let error = model.errorMessage {
                    Section { ErrorText(error) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                if let confirmation = model.codeConfirmation, !confirmation.isConfirmed {
                    Button("Pair") { model.confirmCode() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("confirm-pairing-code")
                } else if model.isChoosingMac {
                    Button("Continue") { model.pair() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selection == nil)
                        .accessibilityIdentifier("pair-mac")
                }
            }
            .padding()
        }
        .frame(width: 440, height: 400)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var macList: some View {
        Section {
            if model.pairableMacs.isEmpty {
                if let message = model.discoveryMessage {
                    ErrorText(message)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs…").foregroundStyle(.secondary)
                    }
                }
            } else {
                Picker("Mac", selection: $model.selection) {
                    ForEach(model.pairableMacs) { mac in Text(mac.name).tag(Optional(mac.id)) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            ForEach(model.versionMismatches, id: \.self) { explanation in
                Text(explanation).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Macs Waiting to Pair")
        } footer: {
            switch model.role {
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
}

#if DEBUG
#Preview("Add Mac", traits: .sizeThatFitsLayout) {
    AddMacViewController(model: AddMacModel(
        macs: PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .manager, browses: false)
    ))
}
#Preview("Add Mac Code", traits: .sizeThatFitsLayout) {
    let macs = PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .manager, browses: false)
    requestPreviewPairing(from: macs, with: HostManagement(store: PreviewSecretStore(), name: "m1pro", advertises: false))
    return AddMacViewController(model: AddMacModel(macs: macs))
}
#Preview("Dashboard Add Mac", traits: .sizeThatFitsLayout) {
    AddMacViewController(model: AddMacModel(
        macs: PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .dashboard, browses: false)
    ))
}
#endif
