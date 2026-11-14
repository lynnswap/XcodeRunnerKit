import AppKit
import Observation
import SwiftUI

/// Whether a paired Mac answers and, while it does not, when its settings were last read.
struct MacConnection {
    let macName: String
    let status: PairedMacs.Status
    /// When the Mac's settings were last read, for a Mac that does not answer.
    let settingsReadAt: Date?
    /// What the Mac that is paired with it does with it.
    let role: PairingRole
    /// The Mac that is paired with it: this Mac, or the host that a dashboard reaches it through.
    let pairedWith: MacReference
    /// What the list that the Mac is in has to tell: a refused change, a Mac that was removed but could not be told,
    /// or pairings that could not be read.
    let message: String?

    @MainActor
    init(of mac: ListedMac, in macs: any MacList) {
        macName = mac.name
        status = macs.status(of: mac.id)
        settingsReadAt = status == .online ? nil : macs.settings(of: mac.id)?.readAt
        role = macs.role
        pairedWith = macs.pairedWith
        message = macs.message
    }
}

extension PairedMacs {
    /// What a host that a dashboard shows last answered, while it answers. Values from an earlier read may have
    /// changed since, so the host's panes show only the connection while it does not.
    func answer(of host: HostPairing.ID) -> (settings: PairedMacSettings, report: HostSettingsReport, github: GitHubReport)? {
        guard status(of: host) == .online, let settings = settings(of: host), let report = settings.report,
              let github = settings.github else { return nil }
        return (settings, report, github)
    }
}

/// What a Mac's pane shows and does: this Mac in its own window, a Mac that this Mac paired with, or a Mac that a
/// dashboard reaches through its host.
@MainActor @Observable
final class MacPaneModel {
    private enum Source {
        case thisMac(HostSettingsModel)
        case listed(any MacList, HostPairing.ID)
    }

    private let source: Source
    private let relay: (hosts: PairedMacs, host: HostPairing.ID)?
    private let registrationsChanged: @MainActor () async -> Void
    private let removed: @MainActor () -> Void
    private(set) var isRemoving = false

    init(settings: HostSettingsModel) {
        source = .thisMac(settings)
        relay = nil
        registrationsChanged = {}
        removed = {}
    }

    /// - Parameters:
    ///   - macs: The list that the Mac is in.
    ///   - relay: The host that a dashboard reaches the Mac through.
    ///   - registrationsChanged: Called after the Mac saved a different job limit or different runner labels. A host
    ///     that manages the Mac registers its runners, and updates them then.
    ///   - removed: Called after the pairing ended and the Mac left the list.
    init(
        macs: any MacList, id: HostPairing.ID, relay: (hosts: PairedMacs, host: HostPairing.ID)? = nil,
        registrationsChanged: @escaping @MainActor () async -> Void = {}, removed: @escaping @MainActor () -> Void
    ) {
        source = .listed(macs, id)
        self.relay = relay
        self.registrationsChanged = registrationsChanged
        self.removed = removed
    }

    private var thisMac: HostSettingsModel? {
        if case .thisMac(let settings) = source { settings } else { nil }
    }

    /// A listed Mac's settings as they were last read and as they are edited here.
    private var paired: PairedMacSettings? {
        if case .listed(let macs, let id) = source { macs.settings(of: id) } else { nil }
    }

    /// Whether the host that a dashboard reaches the Mac through answers. The host's list of Macs is as old as its
    /// last answer.
    private var relayAnswers: Bool { relay.map { $0.hosts.answer(of: $0.host) != nil } ?? true }

    /// The Mac in its list. `nil` for this Mac, and for a Mac that left the list.
    var listedMac: ListedMac? {
        if case .listed(let macs, let id) = source { macs.listedMacs.first { $0.id == id } } else { nil }
    }

    var mac: MacReference { thisMac == nil ? MacReference(name: listedMac?.name ?? "Mac") : .thisMac }

    /// Whether the Mac left its list, so that the pane has nothing to show.
    var isRemoved: Bool { thisMac == nil && relayAnswers && listedMac == nil }

    /// The connection to a paired Mac, or to the host that a dashboard reaches the Mac through while that host does
    /// not answer.
    var connection: MacConnection? {
        guard case .listed(let macs, _) = source else { return nil }
        if let relay, !relayAnswers {
            return relay.hosts.mac(relay.host).map { MacConnection(of: $0.listed, in: relay.hosts) }
        }
        return listedMac.map { MacConnection(of: $0, in: macs) }
    }

    /// The Mac's settings. Settings from an earlier read may have changed since, so another Mac has them only while
    /// it answers.
    var report: HostSettingsReport? {
        switch source {
        case .thisMac(let settings): HostSettingsReport(settings)
        case .listed(let macs, let id): relayAnswers && macs.status(of: id) == .online ? macs.settings(of: id)?.report : nil
        }
    }

    // MARK: Pairing

    /// This Mac's pairings with the Macs that manage and show it. Another Mac's pairings are changed on that Mac.
    var management: HostManagement? { thisMac?.management }
    /// Whether another Mac can manage this Mac, which then manages no Macs itself.
    var canAllowManagement: Bool { thisMac?.canAllowManagement ?? false }
    var managedMacCount: Int { thisMac?.managedMacs.macs.count ?? 0 }
    /// What this Mac's last changes to the Macs that it manages left to tell.
    var managedMacsMessage: String? { thisMac?.managedMacs.message }

    // MARK: Runner services

    var isChangingPause: Bool { paired?.isChangingPause ?? false }
    /// Why the Mac did not pause or resume.
    var pauseError: String? { thisMac?.pauseError ?? paired?.pauseError }

    /// Pauses or resumes the Mac, which stops or starts its runner services without changing their registrations.
    func setPaused(_ isPaused: Bool) {
        switch source {
        case .thisMac(let settings): settings.setPaused(isPaused)
        case .listed(let macs, let id): Task { await macs.setPaused(isPaused, of: id) }
        }
    }

    // MARK: Runner labels

    /// The labels being edited for the Mac's runners, separated by commas.
    var runnerLabelsInput: String {
        get { thisMac?.runnerLabelsInput ?? paired?.runnerLabelsInput ?? "" }
        set {
            thisMac?.runnerLabelsInput = newValue
            paired?.runnerLabelsInput = newValue
        }
    }

    var isSavingRunnerLabels: Bool { thisMac?.isSavingRunnerLabels ?? paired?.isSavingRunnerLabels ?? false }
    var runnerLabelsError: String? { thisMac?.runnerLabelsError ?? paired?.runnerLabelsError }

    func saveRunnerLabels() {
        Task {
            switch source {
            case .thisMac(let settings): await settings.saveRunnerLabelsInput()
            case .listed(let macs, let id): if await macs.saveRunnerLabels(of: id) { await registrationsChanged() }
            }
        }
    }

    // MARK: Xcode execution

    /// The job limit and Simulator retention being edited.
    var poolDraft: PoolSettingsDraft {
        get { thisMac?.poolDraft ?? paired?.poolDraft ?? PoolSettingsDraft() }
        set {
            thisMac?.poolDraft = newValue
            paired?.poolDraft = newValue
        }
    }

    var isApplyingPoolConfiguration: Bool { thisMac?.isSaving ?? paired?.isSaving ?? false }
    var canApplyPoolConfiguration: Bool { thisMac?.canApplyPoolConfiguration ?? paired?.canApplyPoolConfiguration ?? false }
    var poolConfigurationError: String? { thisMac?.saveError ?? paired?.saveError }

    func applyPoolConfiguration() {
        Task {
            switch source {
            case .thisMac(let settings): await settings.applyPoolConfiguration()
            case .listed(let macs, let id): if await macs.applyPoolConfiguration(of: id) { await registrationsChanged() }
            }
        }
    }

    // MARK: Xcode

    /// The selected Xcode's `Contents/Developer` directory, or an empty string for the system selection.
    var xcodeSelectionInput: String {
        get { thisMac?.xcodeSelectionInput ?? paired?.xcodeSelectionInput ?? "" }
        set {
            thisMac?.xcodeSelectionInput = newValue
            paired?.xcodeSelectionInput = newValue
        }
    }

    var isSavingXcode: Bool { thisMac?.isSavingXcode ?? paired?.isSavingXcode ?? false }
    var xcodeSaveError: String? { thisMac?.xcodeSaveError ?? paired?.xcodeSaveError }

    func saveXcodeSelection() {
        Task {
            switch source {
            case .thisMac(let settings): await settings.saveXcodeSelection()
            case .listed(let macs, let id): await macs.saveXcodeSelection(of: id)
            }
        }
    }

    // MARK: Storage

    var storageDirectoryInput: String {
        get { thisMac?.storageDirectoryInput ?? paired?.storageDirectoryInput ?? "" }
        set {
            thisMac?.storageDirectoryInput = newValue
            paired?.storageDirectoryInput = newValue
        }
    }

    var isSavingStorage: Bool { thisMac?.isSavingStorage ?? paired?.isSavingStorage ?? false }
    var storageSaveError: String? { thisMac?.storageSaveError ?? paired?.storageSaveError }
    /// Whether a folder panel can choose the folder. Another Mac's folders are not shown in a panel on this Mac.
    var canChooseStorageDirectory: Bool { thisMac != nil }
    var isRestarting: Bool { thisMac.map { $0.hostState == .stopping } ?? paired?.isRestarting ?? false }
    /// Why the Mac refused to restart for a paired Mac, or why it did not confirm that it restarts.
    var restartError: String? { paired?.restartError }

    func saveStorageDirectory() {
        Task {
            switch source {
            case .thisMac(let settings): await settings.saveStorageSelection()
            case .listed(let macs, let id): await macs.saveStorageDirectory(of: id)
            }
        }
    }

    func chooseStorageDirectory() {
        guard let thisMac else { return }
        Task { await thisMac.chooseStorageDirectory() }
    }

    /// Restarts the Mac's host, which applies its saved storage folder.
    func restart() {
        switch source {
        case .thisMac(let settings): settings.restart()
        case .listed(let macs, let id): Task { await macs.restart(id) }
        }
    }

    // MARK: Removal

    /// Whether the pairing with the Mac can be ended here.
    var canRemove: Bool { listedMac != nil && relayAnswers }

    /// What ending the pairing changes, for the question that confirms it.
    var removalConsequence: String {
        guard case .listed(let macs, _) = source, let mac = listedMac else { return "" }
        return switch macs.role {
        case .manager: "\(mac.name) stops accepting \(macs.pairedWith.object) as its managing host. To manage it again, pair the Macs again."
        case .dashboard: "\(mac.name) stops accepting this Mac as a dashboard. To show it again, pair the Macs again."
        }
    }

    /// Ends the pairing with the Mac.
    func remove() {
        guard case .listed(let macs, let id) = source else { return }
        isRemoving = true
        Task {
            await macs.remove(id)
            isRemoving = false
            if !macs.listedMacs.contains(where: { $0.id == id }) { removed() }
        }
    }

    /// Reads another Mac's settings every few seconds until the task is cancelled. This Mac's settings need no
    /// reading.
    func watch() async {
        guard case .listed(let macs, let id) = source else { return }
        if let relay {
            // The host's answers tell whether its list of Macs is current.
            async let host: Void = relay.hosts.watchSettings(of: relay.host)
            await macs.watchSettings(of: id)
            await host
        } else {
            await macs.watchSettings(of: id)
        }
    }
}

/// A Mac's pane: its pairings, runner services, and execution settings.
@MainActor
final class MacViewController: NSHostingController<MacPaneView> {
    init(model: MacPaneModel) {
        super.init(rootView: MacPaneView(model: model))
        // The split view and the window decide the pane's size.
        sizingOptions = []
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
struct MacPaneView: View {
    @Bindable var model: MacPaneModel
    @State private var isConfirmingRemoval = false

    var body: some View {
        content.task { await model.watch() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isRemoved {
            ContentUnavailableView("This Mac was removed", systemImage: "desktopcomputer")
        } else {
            Form {
                // Other Macs' changes to this Mac's settings appear below, so who can make them comes first.
                if let management = model.management {
                    HostManagementSection(model: model, management: management)
                    HostDashboardsSection(management: management)
                }
                if let connection = model.connection {
                    Section {
                        MacConnectionRows(connection: connection)
                        if let report = model.report { HostStatusRows(settings: report) }
                    }
                }
                if let report = model.report { settings(report) }
                if model.canRemove, let mac = model.listedMac { removal(of: mac) }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func settings(_ report: HostSettingsReport) -> some View {
        RunnerServicesSection(
            settings: report, mac: model.mac, isChangingPause: model.isChangingPause, pauseError: model.pauseError,
            setPaused: { model.setPaused($0) }
        ) {
            if let name = model.mac.name {
                Text("Processes on \(name).")
            } else {
                Text("Processes on this Mac. Overview shows each repository's connection and job counts from GitHub.")
            }
        }
        RunnerLabelsSection(
            labels: $model.runnerLabelsInput, isSaving: model.isSavingRunnerLabels, saveError: model.runnerLabelsError,
            mac: model.mac
        ) {
            model.saveRunnerLabels()
        }
        XcodeExecutionSection(
            settings: report, draft: $model.poolDraft, isSaving: model.isApplyingPoolConfiguration,
            canApply: model.canApplyPoolConfiguration, saveError: model.poolConfigurationError
        ) {
            model.applyPoolConfiguration()
        }
        XcodeSection(
            settings: report, selection: $model.xcodeSelectionInput, isSaving: model.isSavingXcode,
            saveError: model.xcodeSaveError, mac: model.mac
        ) {
            model.saveXcodeSelection()
        }
        StorageSection(
            settings: report, directory: $model.storageDirectoryInput, isSaving: model.isSavingStorage,
            saveError: model.storageSaveError, mac: model.mac, isRestarting: model.isRestarting,
            restartError: model.restartError,
            choose: model.canChooseStorageDirectory ? { model.chooseStorageDirectory() } : nil,
            restart: { model.restart() }
        ) {
            model.saveStorageDirectory()
        }
    }

    private func removal(of mac: ListedMac) -> some View {
        Section {
            HStack {
                Spacer()
                Button(model.isRemoving ? "Removing…" : "Remove Mac…", role: .destructive) { isConfirmingRemoval = true }
                    .disabled(model.isRemoving)
                    .accessibilityIdentifier("remove-mac")
            }
        } footer: {
            Text("Removing ends the pairing on both Macs. Runner services on \(mac.name) keep running.")
        }
        .confirmationDialog("Remove \(mac.name)?", isPresented: $isConfirmingRemoval) {
            Button("Remove", role: .destructive) { model.remove() }
        } message: {
            Text(model.removalConsequence)
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
                Image(systemName: connection.status.systemImage).foregroundStyle(connection.status.tint)
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
