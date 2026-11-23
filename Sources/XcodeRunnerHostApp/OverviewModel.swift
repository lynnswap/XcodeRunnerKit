import Foundation
import Observation
import XcodeRunnerHostSupport

/// What the Settings pane shows and does for a Mac: this Mac in its own window, or a host on a dashboard. It has the
/// Mac's roles, GitHub sign-in, repositories, and pairings.
@MainActor @Observable
final class OverviewModel: PaneSaving {
    private enum Source {
        case thisMac(HostSettingsModel)
        case host(PairedMacs, PairedMac)
    }

    private let source: Source
    private let pairManagedMac: @MainActor () -> Void
    /// Pairs this Mac as a dashboard with a host on another Mac. `nil` where the window shows no such hosts.
    let showHost: (@MainActor () -> Void)?
    private let shownHosts: PairedMacs?
    /// What the list of those hosts has to tell: a host that was removed but could not be told, or pairings that
    /// could not be read.
    var shownHostsMessage: String? { shownHosts?.message }

    /// - Parameters:
    ///   - addMac: Pairs this Mac with a Mac for it to manage.
    ///   - shownHosts: The hosts on other Macs that the window shows after this Mac.
    ///   - showHost: Pairs this Mac as a dashboard with another of them.
    init(
        settings: HostSettingsModel, addMac: @escaping @MainActor () -> Void, shownHosts: PairedMacs? = nil,
        showHost: (@MainActor () -> Void)? = nil
    ) {
        source = .thisMac(settings)
        pairManagedMac = addMac
        self.shownHosts = shownHosts
        self.showHost = showHost
    }

    /// - Parameters:
    ///   - host: A host that the dashboard shows.
    ///   - addMac: Pairs the host with a Mac for it to manage.
    init(hosts: PairedMacs, host: PairedMac, addMac: @escaping @MainActor () -> Void) {
        source = .host(hosts, host)
        pairManagedMac = addMac
        shownHosts = nil
        showHost = nil
    }

    var mac: MacReference {
        switch source {
        case .thisMac: .thisMac
        case .host(_, let host): MacReference(name: host.name)
        }
    }

    /// The Mac's sign-in and repositories. A dashboard has none while the host does not answer.
    var github: GitHubReport? {
        switch source {
        case .thisMac(let settings): settings.github.report
        case .host(let hosts, let host): hosts.answer(of: host.id)?.github
        }
    }

    /// The connection to a host that does not answer, which the pane shows in place of the host's status.
    var connection: MacConnection? {
        guard case .host(let hosts, let host) = source, hosts.answer(of: host.id) == nil else { return nil }
        return MacConnection(of: host.listed, in: hosts)
    }

    /// What a dashboard's last requests to the host left to tell: a refusal, or a Mac that was removed but could not
    /// be told. Removing one of the host's Macs returns to this pane, where its notice stays visible.
    var notices: [String] {
        if case .thisMac(let settings) = source {
            return settings.managedMacs.settingsSyncErrors
        }
        guard case .host(let hosts, let host) = source, let answer = hosts.answer(of: host.id) else { return [] }
        return [answer.settings.githubError, hosts.macsManaged(by: host.id).message].compactMap { $0 }
    }

    // MARK: GitHub

    /// The repository selection being edited.
    var selection: Set<Int> {
        get {
            switch source {
            case .thisMac(let settings): settings.github.selectedRepositoryIDs
            case .host(let hosts, let host): hosts.settings(of: host.id)?.selectedRepositoryIDs ?? []
            }
        }
        set {
            switch source {
            case .thisMac(let settings): settings.github.selectedRepositoryIDs = newValue
            case .host(let hosts, let host): hosts.settings(of: host.id)?.selectedRepositoryIDs = newValue
            }
        }
    }

    /// Whether the GitHub controls wait: for a host to answer a request, or for this Mac to apply a job limit, which
    /// changes the runners that it registers.
    var isWaitingForGitHub: Bool {
        switch source {
        case .thisMac(let settings): settings.isSaving
        case .host(let hosts, let host): hosts.settings(of: host.id)?.isChangingGitHub ?? false
        }
    }

    /// Whether the selection can be applied now: it differs from the saved one, or registering runners for the saved
    /// one failed, which applying it again retries.
    private var canApplySelection: Bool {
        guard let github, !github.isBusy, !github.isLoadingRepositories else { return false }
        return selection != github.savedRepositoryIDs || github.errorMessage != nil
            || github.runnerStatuses.contains { $0.errorMessage != nil }
    }

    /// Starts the sign-in, whose code the pane then shows.
    func signIn() {
        switch source {
        case .thisMac(let settings): settings.github.signIn()
        case .host(let hosts, let host): Task { await hosts.signIn(to: host.id) }
        }
    }

    func cancelSignIn() {
        switch source {
        case .thisMac(let settings): settings.github.cancelConnection()
        case .host(let hosts, let host): Task { await hosts.cancelSignIn(to: host.id) }
        }
    }

    func signOut(confirmedLogin: String) {
        switch source {
        case .thisMac(let settings): Task { await settings.github.signOut(confirmedLogin: confirmedLogin) }
        case .host(let hosts, let host): Task { await hosts.signOut(of: host.id, confirmedLogin: confirmedLogin) }
        }
    }

    /// Opens the page that chooses the GitHub App's repositories. A host's page opens in this Mac's browser.
    func addRepositories() {
        switch source {
        case .thisMac(let settings): settings.github.installApp()
        case .host(let hosts, let host): hosts.addRepositories(to: host.id)
        }
    }

    func reloadRepositories() {
        switch source {
        case .thisMac(let settings): Task { await settings.github.reloadRepositories() }
        case .host(let hosts, let host): Task { await hosts.reloadRepositories(of: host.id) }
        }
    }

    var jobOptions: HostJobOptions? {
        switch source {
        case .thisMac(let settings): settings.management.manager == nil ? settings.jobOptions : nil
        case .host(let hosts, let host): hosts.answer(of: host.id)?.report.jobOptions
        }
    }

    private var jobOptionEdits: HostJobOptions.Edits {
        get {
            switch source {
            case .thisMac(let settings): settings.jobOptionEdits
            case .host(let hosts, let host): hosts.settings(of: host.id)?.jobOptionEdits ?? [:]
            }
        }
        set {
            switch source {
            case .thisMac(let settings): settings.jobOptionEdits = newValue
            case .host(let hosts, let host): hosts.settings(of: host.id)?.jobOptionEdits = newValue
            }
        }
    }

    subscript(jobOptions kind: HostJobOptions.Kind) -> [HostJobOptions.Entry] {
        get { jobOptionEdits[kind] ?? jobOptions?[kind] ?? [] }
        set {
            jobOptionEdits[kind] = newValue == jobOptions?[kind] ? nil : newValue
            jobOptionsSaveError = nil
        }
    }

    private var jobOptionsSaveError: String?
    var jobOptionsError: String? {
        if let jobOptionsSaveError { return jobOptionsSaveError }
        switch source {
        case .thisMac(let settings): return settings.jobOptionsReadError
        case .host(let hosts, let host): return hosts.answer(of: host.id)?.report.jobOptionsReadError
        }
    }

    private var canSaveSelection: Bool {
        guard let github, github.accountLogin != nil, github.managerName == nil else { return false }
        return canApplySelection && !isWaitingForGitHub
    }

    private var canSaveOptions: Bool { jobOptions != nil && !jobOptionEdits.isEmpty }
    var canSave: Bool { !isSaving && (canSaveOptions || canSaveSelection) }

    private var isApplyingSelection = false
    private(set) var isSavingJobOptions = false
    var isSaving: Bool { isApplyingSelection || isSavingJobOptions || github?.isSavingSelection == true }

    private var saveCount = 0
    var saveProgress: (completed: Int, total: Int) {
        (max(0, saveCount - (isSavingJobOptions ? 1 : 0) - (isApplyingSelection ? 1 : 0)), saveCount)
    }

    var hasEdits: Bool {
        if canSaveOptions { return true }
        guard let github, github.accountLogin != nil, github.managerName == nil else { return false }
        return selection != github.savedRepositoryIDs
    }

    func revert() {
        if let github { selection = github.savedRepositoryIDs }
        jobOptionEdits = [:]
        jobOptionsSaveError = nil
    }

    func save() {
        guard canSave else { return }
        isApplyingSelection = canSaveSelection
        isSavingJobOptions = canSaveOptions
        saveCount = (isSavingJobOptions ? 1 : 0) + (isApplyingSelection ? 1 : 0)
        Task {
            if isSavingJobOptions {
                let edits = jobOptionEdits
                do {
                    switch source {
                    case .thisMac(let settings):
                        try settings.saveJobOptions(edits)
                        await settings.managedMacs.distributeSettings()
                    case .host(let hosts, let host):
                        try await hosts.saveJobOptions(edits, of: host.id)
                    }
                    if jobOptionEdits == edits { jobOptionEdits = [:] }
                    jobOptionsSaveError = nil
                } catch { jobOptionsSaveError = error.localizedDescription }
            }
            isSavingJobOptions = false
            if isApplyingSelection {
                switch source {
                case .thisMac(let settings): await settings.github.applyRepositorySelection()
                case .host(let hosts, let host): await hosts.applyRepositorySelection(of: host.id)
                }
                isApplyingSelection = false
            }
        }
    }

    // MARK: Other Macs

    /// How many Macs the Mac manages. Their panes are in the sidebar.
    var managedMacCount: Int {
        switch source {
        case .thisMac(let settings): settings.managedMacs.macs.count
        case .host(let hosts, let host): hosts.macsManaged(by: host.id).listedMacs.count
        }
    }

    /// Whether the Mac can pair with a Mac for it to manage. A Mac that another Mac manages cannot.
    var canAddManagedMac: Bool {
        switch source {
        case .thisMac(let settings): settings.canAddMacs
        case .host(let hosts, let host): hosts.macsManaged(by: host.id).canAddMacs
        }
    }

    /// Pairs the Mac with a Mac for it to manage.
    func addManagedMac() { pairManagedMac() }

    /// This Mac's pairings with the Macs that manage and show it. Another Mac's pairings are changed on that Mac.
    var management: HostManagement? {
        if case .thisMac(let settings) = source { settings.management } else { nil }
    }

    // MARK: Roles

    /// Whether this Mac is a host, which signs in to GitHub and registers runners for itself and the Macs that it
    /// manages. It is none once a host on another Mac manages it, or while it waits for one. A host on a dashboard
    /// has no roles here, because they are changed on that Mac.
    var isHost: Bool? {
        guard let management else { return nil }
        return management.manager == nil && management.pairingWindow?.role != .manager
    }

    /// Whether this Mac can stop being a host now. A Mac that manages Macs cannot, and one wait for a Mac runs at a
    /// time.
    var canStopHosting: Bool {
        guard case .thisMac(let settings) = source else { return false }
        return settings.canAllowManagement && settings.management.pairingWindow == nil
    }

    /// Waits for a host on another Mac to pair with this Mac and manage it.
    func stopHosting() {
        guard canStopHosting else { return }
        management?.allowManagement()
    }

    /// Makes this Mac a host again: it stops waiting for a host, or ends its management by one.
    func becomeHost() {
        guard let management else { return }
        if management.manager != nil { management.stopManagement() } else { management.cancelPairing() }
    }

    /// Whether this Mac is a runner, which takes jobs. A host that is none still registers the runners of the Macs
    /// that it manages.
    var isRunner: Bool? {
        if case .thisMac(let settings) = source { !settings.isPaused } else { nil }
    }

    /// Resumes or pauses this Mac, which starts or stops its runner services without changing their registrations.
    func setRunner(_ isRunner: Bool) {
        if case .thisMac(let settings) = source { settings.setPaused(!isRunner) }
    }

    /// Why this Mac did not pause or resume.
    var runnerError: String? {
        if case .thisMac(let settings) = source { settings.pauseError } else { nil }
    }

    /// What this Mac's last changes to the Macs that it manages left to tell.
    var managedMacsMessage: String? {
        if case .thisMac(let settings) = source { settings.managedMacs.message } else { nil }
    }

    /// Reads a host's settings every few seconds until the task is cancelled. This Mac's settings need no reading.
    func watch() async {
        if case .host(let hosts, let host) = source { await hosts.watchSettings(of: host.id) }
    }
}
