import AppKit
import SwiftUI

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
    HostPreview.requestPairing(from: macs, with: HostManagement(store: PreviewSecretStore(), name: "m1pro", advertises: false))
    return AddMacViewController(model: AddMacModel(macs: macs))
}
#Preview("Dashboard Add Mac", traits: .sizeThatFitsLayout) {
    AddMacViewController(model: AddMacModel(
        macs: PairedMacs(store: PreviewSecretStore(), name: HostPane.macName, role: .dashboard, browses: false)
    ))
}
#endif
