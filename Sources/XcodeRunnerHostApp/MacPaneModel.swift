import Foundation
import Observation

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
final class MacPaneModel: PaneSaving {
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
    // A value can be saved once it is edited, and after a failure, when saving the same value again can repair what
    // failed.

    var canSaveRunnerLabels: Bool {
        guard let report, !isSavingRunnerLabels else { return false }
        return RunnerLabels.parse(runnerLabelsInput) != report.runnerLabels || runnerLabelsError != nil
    }
    var runnerLabelsError: String? { thisMac?.runnerLabelsError ?? paired?.runnerLabelsError }

    private func saveRunnerLabels() async {
        switch source {
        case .thisMac(let settings): await settings.saveRunnerLabelsInput()
        case .listed(let macs, let id): if await macs.saveRunnerLabels(of: id) { await registrationsChanged() }
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
    /// A pool without saved settings takes the ones shown.
    var canApplyPoolConfiguration: Bool {
        guard let report, thisMac?.canApplyPoolConfiguration ?? paired?.canApplyPoolConfiguration ?? false else { return false }
        let failed = report.poolError != nil || poolConfigurationError != nil || report.configurationCleanupError != nil
            || report.simulatorPoolError != nil
        return report.isNewPool || poolDraft.isEdited || failed
    }
    var poolConfigurationError: String? { thisMac?.saveError ?? paired?.saveError }

    private func applyPoolConfiguration() async {
        switch source {
        case .thisMac(let settings): await settings.applyPoolConfiguration()
        case .listed(let macs, let id): if await macs.applyPoolConfiguration(of: id) { await registrationsChanged() }
        }
    }

    // MARK: Xcode

    /// An Xcode that the Mac's jobs can use.
    struct XcodeChoice: Identifiable, Equatable {
        /// Names the Xcode to the Mac that saves it.
        let id: String
        let title: String
    }

    /// The Xcodes to choose from: the ones installed on the Mac and, so that the choices show what is saved, a saved
    /// one that is not among them.
    var xcodeChoices: [XcodeChoice] {
        guard let report else { return [] }
        var choices = report.installedXcodes.map {
            XcodeChoice(id: $0.developerDirectory.path(percentEncoded: false), title: $0.name)
        }
        if let savedXcode, !choices.contains(where: { $0.id == savedXcode }) {
            // People know an Xcode by its app, and a developer directory outside an app only by its path.
            let name = Self.xcodeApplication(at: savedXcode).map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
                ?? savedXcode
            choices.append(XcodeChoice(id: savedXcode, title: report.savedXcodeIsMissing ? "\(name) (not installed)" : name))
        }
        return choices
    }

    /// The chosen Xcode, or `nil` for the one that `xcode-select` names.
    var selectedXcode: XcodeChoice.ID? {
        get {
            let input = thisMac?.xcodeSelectionInput ?? paired?.xcodeSelectionInput ?? ""
            return input.isEmpty ? nil : input
        }
        set {
            thisMac?.xcodeSelectionInput = newValue ?? ""
            paired?.xcodeSelectionInput = newValue ?? ""
        }
    }

    /// The saved Xcode, as its choice names it.
    private var savedXcode: XcodeChoice.ID? { report?.savedDeveloperDirectory?.path(percentEncoded: false) }

    /// The Xcode app that holds a developer directory, or `nil` for a directory that is not inside an app.
    private static func xcodeApplication(at developerDirectory: String) -> String? {
        let inApplication = "/Contents/Developer"
        return developerDirectory.hasSuffix(inApplication) ? String(developerDirectory.dropLast(inApplication.count)) : nil
    }

    var isSavingXcode: Bool { thisMac?.isSavingXcode ?? paired?.isSavingXcode ?? false }
    var canSaveXcodeSelection: Bool {
        !isSavingXcode && (selectedXcode != savedXcode || report?.xcodeError != nil || xcodeSaveError != nil)
    }
    /// Why jobs that name no Xcode fail: the saved Xcode is no longer on the Mac.
    var savedXcodeProblem: String? {
        guard report?.savedXcodeIsMissing == true, let savedXcode else { return nil }
        let location = Self.xcodeApplication(at: savedXcode) ?? savedXcode
        return "The saved Xcode at \(location) is no longer installed on \(mac.object). Jobs that name no Xcode fail until another one is saved."
    }
    var xcodeSaveError: String? { thisMac?.xcodeSaveError ?? paired?.xcodeSaveError }

    private func saveXcodeSelection() async {
        switch source {
        case .thisMac(let settings): await settings.saveXcodeSelection()
        case .listed(let macs, let id): await macs.saveXcodeSelection(of: id)
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
    var canEditStorageDirectory: Bool { report?.canEditStorage == true && !isSavingStorage }
    var canSaveStorageDirectory: Bool {
        guard canEditStorageDirectory, let report else { return false }
        return storageDirectoryInput != report.savedStorageDirectory?.path(percentEncoded: false) ?? ""
            || report.storageError != nil || storageSaveError != nil
    }
    var storageSaveError: String? { thisMac?.storageSaveError ?? paired?.storageSaveError }
    /// Whether a folder panel can choose the folder. Another Mac's folders are not shown in a panel on this Mac.
    var canChooseStorageDirectory: Bool { thisMac != nil }
    var isRestarting: Bool { thisMac.map { $0.hostState == .stopping } ?? paired?.isRestarting ?? false }
    /// Why the Mac refused to restart for a paired Mac, or why it did not confirm that it restarts.
    var restartError: String? { paired?.restartError }

    private func saveStorageDirectory() async {
        switch source {
        case .thisMac(let settings): await settings.saveStorageSelection()
        case .listed(let macs, let id): await macs.saveStorageDirectory(of: id)
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

    // MARK: Saving

    /// Whether a save from this pane runs now.
    private(set) var isSaving = false

    var canSave: Bool {
        !isSaving && (canSaveRunnerLabels || canApplyPoolConfiguration || canSaveXcodeSelection || canSaveStorageDirectory)
    }

    /// Saves the values that can be saved now, one after the other, because the Mac applies one change at a time.
    func save() {
        guard canSave else { return }
        let labels = canSaveRunnerLabels, pool = canApplyPoolConfiguration, xcode = canSaveXcodeSelection
        let storage = canSaveStorageDirectory
        isSaving = true
        Task {
            if labels { await saveRunnerLabels() }
            if pool { await applyPoolConfiguration() }
            if xcode { await saveXcodeSelection() }
            if storage { await saveStorageDirectory() }
            isSaving = false
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
