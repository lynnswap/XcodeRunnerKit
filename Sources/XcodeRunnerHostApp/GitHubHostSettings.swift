import AppKit
import Foundation
import Observation
import XcodeRunnerHostSupport
import XcodeRunnerKit

struct GitHubHostConfiguration: Codable, Equatable {
    var repositories: [GitHubRepository] = []
    /// Repositories that left the selection while this Mac still had their runners.
    var unlinkedRepositories: [GitHubRepository] = []

    static func load(from url: URL) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Self() }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension GitHubHostConfiguration {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try container.decode([GitHubRepository].self, forKey: .repositories)
        // Settings saved before unlinking removed runners have no unlinked repositories.
        unlinkedRepositories = try container.decodeIfPresent([GitHubRepository].self, forKey: .unlinkedRepositories) ?? []
    }
}

@MainActor @Observable
final class GitHubHostSettings {
    let app: GitHubApp
    private let installation: HostInstallation
    private let record: URL
    private let authentication: GitHubAuthentication
    @ObservationIgnored private var packageAccess: GitHubPackageAccess?

    private let client: GitHubClient
    private let provisioner: RunnerProvisioner
    private let pool: HostExecutionPool
    private let openURL: @MainActor (URL) -> Bool
    /// The Macs that this host manages. They register runners for the same repositories as this Mac.
    @ObservationIgnored weak var pairedMacs: PairedMacs?
    /// This Mac's pairing with a managing host, which then registers this Mac's runners instead.
    @ObservationIgnored weak var management: HostManagement?
    private var pairedProvisioners: [HostPairing.ID: RunnerProvisioner] = [:]
    private var configuration = GitHubHostConfiguration()
    private var connectionTask: Task<Void, Never>?
    private var synchronizationTask: Task<Void, Never>?
    var selectedRepositoryIDs: Set<Int> = []
    private(set) var account: GitHubAccount?
    private(set) var repositories: [GitHubRepository] = []
    /// The installations of the app that GitHub listed with the repositories.
    private var installations: [GitHubInstallation] = []
    private(set) var runnerStatuses: [RepositoryRunnerStatus] = []
    private(set) var deviceAuthorization: GitHubDeviceAuthorization?
    private var packageAccessError: String?
    private(set) var errorMessage: String?
    private(set) var isConnecting = false
    private(set) var isSynchronizing = false
    private(set) var isLoadingRepositories = false
    private(set) var hasRestored = false
    private(set) var isSavingSelection = false
    private var isShuttingDown = false
    var storageIsReady = false

    /// Connection, selection, and registration updates serialize changes to the saved GitHub settings.
    var isBusy: Bool { isConnecting || isSynchronizing || isSavingSelection }
    var canReloadRepositories: Bool { !isBusy && !isLoadingRepositories }
    var canDisconnect: Bool { !isBusy && !isLoadingRepositories }

    init(
        installation: HostInstallation, pool: HostExecutionPool, app: GitHubApp = .xcodeHomeRunner,
        client: GitHubClient = .init(), authentication: GitHubAuthentication? = nil, provisioner: RunnerProvisioner? = nil,
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.installation = installation
        self.app = app
        self.pool = pool
        self.client = client
        self.openURL = openURL
        self.record = installation.hostRoot.appending(path: "github-host.json")
        self.authentication = authentication
            ?? GitHubAuthentication(hostRoot: installation.hostRoot, clientID: app.clientID, client: client)
        self.provisioner = provisioner ?? RunnerProvisioner(
            installation: installation,
            installerURL: Bundle.main.bundleURL.appending(path: "Contents/Resources/HostSetup/install-github-runner.sh"),
            client: client
        )
        do {
            configuration = try GitHubHostConfiguration.load(from: record)
            selectedRepositoryIDs = Set(configuration.repositories.map(\.id))
        } catch {
            errorMessage = "Could not read GitHub settings: \(error.localizedDescription)"
        }
    }

    var selectableRepositories: [GitHubRepository] {
        var combined: [Int: GitHubRepository] = [:]
        for repository in configuration.repositories + repositories { combined[repository.id] = repository }
        return combined.values.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    private struct ManagedPackages: Codable {
        let manager: UUID
        let repositories: [String]
    }

    private var routesFile: URL { installation.hostRoot.appending(path: "managed-package-repositories.json") }
    private var managedPackageRelay: GitHubPackageAccess.Relay?
    var packageRouting: PackageRouting {
        if let packageAccessError { return .failed(packageAccessError) }
        return managedPackageRelay?.routing ?? .applied([])
    }

    func packageRepositories() throws -> [String] {
        try GitHubPackageAccess.repositories(in: installation.packageRepositories)
    }

    func changePackageAccess(_ change: PackageAccessChange) async -> HostLinkReply {
        do {
            guard management?.manager == nil else { throw HostSettingsError("Edit package access on the managing host.") }
            var names = try packageRepositories()
            switch change {
            case .list: return .packageRepositories(names)
            case .add(let name):
                guard PackageFetch.validRepository(name) else { throw HostSettingsError("Enter a GitHub repository as OWNER/REPO.") }
                if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
            case .remove(let name):
                names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            names.sort()
            try FileManager.default.createDirectory(at: installation.hostRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(names).write(to: installation.packageRepositories, options: .atomic)
            await preparePackageAccess()
            let deliveryErrors = await pairedMacs?.distributePackages() ?? []
            let errors = [packageAccessError].compactMap { $0 } + deliveryErrors
            if !errors.isEmpty { throw HostSettingsError("Package access was saved. " + errors.joined(separator: " ")) }
            return .packageRepositories(names)
        } catch { return .refused(error.localizedDescription) }
    }

    func routePackages(_ names: [String], from manager: UUID) async throws {
        guard management?.manager?.id == manager else { throw HostSettingsError("This Mac has another managing host.") }
        try FileManager.default.createDirectory(at: installation.hostRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(ManagedPackages(manager: manager, repositories: names)).write(to: routesFile, options: .atomic)
        await preparePackageAccess()
        if let packageAccessError { throw HostSettingsError(packageAccessError) }
    }

    func packageManagerChanged() {
        managedPackageRelay = nil
        Task { await preparePackageAccess() }
    }

    func enablePackageAccess(on installation: HostInstallation) {
        packageAccess = GitHubPackageAccess(installation: installation, authentication: authentication)
    }

    func preparePackageAccess() async {
        guard let packageAccess, !isShuttingDown, !Task.isCancelled else { return }
        let previousError = packageAccessError
        do {
            if let manager = management?.manager {
                let saved: ManagedPackages?
                do { saved = try JSONDecoder().decode(ManagedPackages.self, from: Data(contentsOf: routesFile)) }
                catch CocoaError.fileReadNoSuchFile { saved = nil }
                let names = saved?.manager == manager.id ? saved?.repositories ?? [] : []
                let relay = try await packageAccess.update(manager: manager.id, repositories: names)
                if management?.manager?.id == manager.id { managedPackageRelay = relay }
                packageAccessError = nil
                if errorMessage == previousError { errorMessage = nil }
                return
            }
            managedPackageRelay = nil
            let signedIn = if hasRestored { account != nil } else { try await authentication.account() != nil }
            guard management?.manager == nil, !isShuttingDown else { return }
            if signedIn {
                try await packageAccess.update()
            } else {
                await packageAccess.stop()
            }
            packageAccessError = nil
            if errorMessage == previousError { errorMessage = nil }
        } catch {
            managedPackageRelay = nil
            await packageAccess.stop()
            packageAccessError = "Could not configure private packages: \(error.localizedDescription)"
            if errorMessage == nil || errorMessage == previousError { errorMessage = packageAccessError }
        }
    }

    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        do {
            account = try await authentication.account()
            if account != nil { await loadRepositories() }
        } catch {
            errorMessage = "Could not access GitHub credentials: \(error.localizedDescription)"
        }
    }

    /// The page where the person chooses the app's repositories.
    ///
    /// When the app's only installation is for the person's own account, this is that installation's settings. The
    /// page that installs the app serves every other case: it asks for the account, installs the app where it is
    /// missing, and asks an organization's owner where the person may not change the installation.
    private var installationURL: URL {
        guard let account, installations.count == 1, let installation = installations.first,
              installation.account?.id == account.id, let page = installation.settingsPage
        else { return app.installationURL }
        return page
    }

    func installApp() {
        do { try openBrowser(installationURL) }
        catch { errorMessage = error.localizedDescription }
    }

    /// - Parameter opensBrowser: Whether GitHub's page opens on this Mac. A dashboard opens it on its own Mac.
    func signIn(opensBrowser: Bool = true) {
        guard !isBusy else { return }
        isConnecting = true
        errorMessage = nil
        connectionTask = Task {
            defer { finishConnecting() }
            do {
                let authorization = try await authentication.begin()
                deviceAuthorization = authorization
                if opensBrowser { try openBrowser(authorization.verificationURI) }
                account = try await authentication.finish(authorization)
                await loadRepositories()
            } catch is CancellationError {
            } catch {
                errorMessage = "Could not sign in to GitHub: \(error.localizedDescription)"
            }
        }
    }

    func cancelConnection() {
        connectionTask?.cancel()
    }

    private func finishConnecting() {
        deviceAuthorization = nil
        connectionTask = nil
        isConnecting = false
    }

    /// What this Mac's window shows, and what this Mac sends a dashboard.
    var report: GitHubReport {
        GitHubReport(
            accountLogin: account?.login, hasRestored: hasRestored, isConnecting: isConnecting,
            signInCode: deviceAuthorization.map { .init(userCode: $0.userCode, verificationURI: $0.verificationURI) },
            isBusy: isBusy, canReloadRepositories: canReloadRepositories, canDisconnect: canDisconnect,
            isLoadingRepositories: isLoadingRepositories, isSavingSelection: isSavingSelection, isSynchronizing: isSynchronizing,
            supportsRegistrationRetry: true,
            selectableRepositories: selectableRepositories, hasListedRepositories: !repositories.isEmpty,
            savedRepositoryIDs: savedRepositoryIDs, runnerStatuses: runnerStatuses.map(RepositoryRunnerReport.init),
            errorMessage: errorMessage, installationURL: installationURL, addOrganizationURL: app.installationURL,
            managerName: management?.manager?.name, managesMacs: pairedMacs?.macs.isEmpty == false
        )
    }

    func signOut(confirmedLogin: String?) async {
        guard canDisconnect else {
            errorMessage = Self.busy.localizedDescription
            return
        }
        do {
            try await authentication.signOut(confirmedLogin: confirmedLogin)
            account = nil
            if management?.manager == nil { await packageAccess?.stop() }
            repositories = []
            installations = []
            runnerStatuses = []
            errorMessage = nil
        } catch { errorMessage = "Could not disconnect GitHub: \(error.localizedDescription)" }
    }

    func reloadRepositories() async {
        guard canReloadRepositories else { return }
        await loadRepositories()
    }

    func loadRepositories() async {
        guard !isLoadingRepositories else { return }
        isLoadingRepositories = true
        defer { isLoadingRepositories = false }
        await preparePackageAccess()
        do {
            show(try await authenticated { token in
                try await client.listInstallations(accessToken: token)
            })
            errorMessage = packageAccessError
        } catch is CancellationError {
        } catch { await handleGitHubFailure(error, operation: "load repositories") }
    }

    /// Shows what GitHub listed for the app's installations.
    private func show(_ access: GitHubAppAccess) {
        installations = access.installations
        repositories = access.repositories
    }

    var savedRepositoryIDs: Set<Int> { Set(configuration.repositories.map(\.id)) }

    var repositorySettings: HostGitHubRepositorySettings {
        HostGitHubRepositorySettings(
            selectedRepositoryIDs: savedRepositoryIDs.sorted(),
            choices: selectableRepositories.map { HostSettingsRepository(id: $0.id, fullName: $0.fullName) }
        )
    }

    func saveSelection(_ selectedIDs: Set<Int>) throws {
        let draftWasUnedited = selectedRepositoryIDs == savedRepositoryIDs
        var available: [Int: GitHubRepository] = [:]
        for repository in configuration.repositories + repositories { available[repository.id] = repository }
        var next = configuration
        next.repositories = try selectedIDs.sorted().map { id in
            guard let repository = available[id] else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Reload repositories before applying their selection."])
            }
            return repository
        }
        // The next synchronization removes this Mac's runners of the repositories that leave the selection.
        var unlinked: [Int: GitHubRepository] = [:]
        for repository in configuration.unlinkedRepositories + configuration.repositories where !selectedIDs.contains(repository.id) {
            unlinked[repository.id] = repository
        }
        next.unlinkedRepositories = unlinked.values.sorted { $0.id < $1.id }
        try next.save(to: record)
        configuration = next
        if draftWasUnedited { selectedRepositoryIDs = selectedIDs }
    }

    /// Saves through the same owner for GUI and local automation, then reconciles registrations.
    func updateRepositorySelection(_ selectedIDs: Set<Int>) async throws -> String? {
        try beginSelectionUpdate(selectedIDs)
        return await finishSelectionUpdate()
    }

    /// Reserves registration management. A retry uses the host's saved selection, including edits from another dashboard.
    private func beginSelectionUpdate(_ selectedIDs: Set<Int>?) throws {
        guard !isShuttingDown else { throw HostSettingsError("The runner host is stopping.") }
        guard !isBusy, !isLoadingRepositories else { throw Self.busy }
        if let selectedIDs { try saveSelection(selectedIDs) }
        isSavingSelection = true
    }

    private func finishSelectionUpdate() async -> String? {
        defer { isSavingSelection = false }
        return await applySavedRepositorySelection()
    }

    private static let busy = HostSettingsError("GitHub runner management is busy. Retry after the current operation finishes.")

    /// Answers a dashboard's request to read or change this Mac's GitHub settings, the way this Mac's window does.
    ///
    /// A successful registration request acknowledges the saved selection before the host reconciles its runners.
    func answer(_ request: GitHubRequest) async -> HostLinkReply {
        do {
            switch request {
            case .read: break
            case .signIn:
                guard !isBusy else { throw Self.busy }
                // The reply does not wait for GitHub to issue the code, so the dashboard can cancel meanwhile.
                signIn(opensBrowser: false)
            case .cancelSignIn:
                cancelConnection()
                await connectionTask?.value
            case .signOut:
                guard canDisconnect else { throw Self.busy }
                await signOut(confirmedLogin: nil)
            case .disconnectAccount(let confirmedLogin):
                guard canDisconnect else { throw Self.busy }
                await signOut(confirmedLogin: confirmedLogin)
            case .reloadRepositories:
                guard canReloadRepositories else { throw Self.busy }
                await loadRepositories()
            case .applySelection(let selectedIDs):
                do { try beginSelectionUpdate(selectedIDs) }
                catch { throw HostSettingsError("Could not save the repository selection: \(error.localizedDescription)") }
            case .retryRunnerRegistration:
                try beginSelectionUpdate(nil)
            }
            return .github(report)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Registers and removes runners after the selection has been saved.
    func synchronizeSavedSelection() async {
        guard isSavingSelection else { return }
        errorMessage = await finishSelectionUpdate()
    }

    private func applySavedRepositorySelection() async -> String? {
        if configuration.repositories.isEmpty && configuration.unlinkedRepositories.isEmpty {
            runnerStatuses = []
            errorMessage = nil
            return nil
        }
        if let manager = management?.manager {
            return "Repository selection was saved. \(manager.name) registers this Mac's runners while it manages this Mac."
        }
        guard storageIsReady else {
            return "Repository selection was saved. Runner registration changes are pending until host storage is ready."
        }
        await synchronize()
        if isShuttingDown {
            return "Repository selection was saved. Runner registration changes will resume at the next host launch."
        }
        let problems = runnerStatuses.compactMap(\.errorMessage)
        let messages = [errorMessage].compactMap { $0 } + problems
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func applyRepositorySelection(_ selection: Set<Int>?) {
        do {
            try beginSelectionUpdate(selection)
            Task { await synchronizeSavedSelection() }
        } catch { errorMessage = "Could not save the repository selection: \(error.localizedDescription)" }
    }

    /// Registers the selected repositories' runners on this Mac and the Macs it manages, and removes the runners of
    /// repositories that left the selection.
    func synchronize() async {
        guard !isShuttingDown, synchronizationTask == nil, storageIsReady, !isConnecting else { return }
        guard management?.manager == nil else {
            runnerStatuses = []
            return
        }
        guard !configuration.repositories.isEmpty || !configuration.unlinkedRepositories.isEmpty else { runnerStatuses = []; return }
        guard account != nil else {
            errorMessage = "Sign in to synchronize runner registrations. Existing jobs continue using the saved execution limit."
            return
        }
        isSynchronizing = true
        defer {
            synchronizationTask = nil
            isSynchronizing = false
        }
        let task = Task { await performSynchronization() }
        synchronizationTask = task
        await task.value
    }

    private func performSynchronization() async {
        do {
            let selected = configuration.repositories
            let unlinked = configuration.unlinkedRepositories
            let capacity = try await pool.status()?.configuration.maximumConcurrentJobs
            let pairedMacs = self.pairedMacs
            let paired = pairedMacs?.macs ?? []
            pairedProvisioners = pairedProvisioners.filter { id, _ in paired.contains { $0.id == id } }
            let statuses = try await authenticated { token in
                let access = try await client.listInstallations(accessToken: token)
                try Task.checkCancellation()
                show(access)
                let available = access.repositories
                let current = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
                let inaccessible = selected.filter { current[$0.id] == nil }.map { repository in
                    RepositoryRunnerStatus(
                        repository: repository, desiredCount: capacity ?? 0,
                        registeredCount: 0, onlineCount: 0, busyCount: 0, excessCount: 0, problems: [.repositoryInaccessible]
                    )
                } + unlinked.filter { current[$0.id] == nil }.map { repository in
                    // GitHub keeps the registrations until the app can remove them, so the runners stay as well.
                    RepositoryRunnerStatus(
                        repository: repository, desiredCount: 0, registeredCount: 0, onlineCount: 0, busyCount: 0,
                        excessCount: 0, problems: [.repositoryInaccessible], isUnlinked: true
                    )
                }
                let accessible = selected.compactMap { current[$0.id] }
                let accessibleUnlinked = unlinked.compactMap { current[$0.id] }
                var macs: [(name: String?, statuses: [RepositoryRunnerStatus])] = []
                var macName: String?
                do {
                    macs.append((nil, try await reconcile(
                        provisioner, capacity: capacity,
                        missingLimit: "Set Maximum concurrent jobs for this Mac under Runners and choose Save to register runners.",
                        repositories: accessible, unlinked: accessibleUnlinked, token: token
                    )))
                    if let pairedMacs {
                        for mac in paired {
                            macName = mac.name
                            macs.append((mac.name, try await pairedStatuses(
                                of: mac, in: pairedMacs, repositories: accessible, unlinked: accessibleUnlinked, token: token
                            )))
                        }
                    }
                } catch let failure as RunnerProvisioningAuthenticationFailure {
                    // Keep the latest counts visible while the token is refreshed or the user signs in again.
                    runnerStatuses = (RepositoryRunnerStatus.combining(macs + [(macName, failure.statuses)]) + inaccessible)
                        .filter { !$0.hasFinishedRemoval }
                    throw failure.underlyingError
                }
                return RepositoryRunnerStatus.combining(macs) + inaccessible
            }
            runnerStatuses = statuses.filter { !$0.hasFinishedRemoval }
            errorMessage = packageAccessError
            let finished = Set(statuses.filter(\.hasFinishedRemoval).map(\.id))
            if !finished.isEmpty {
                var next = configuration
                next.unlinkedRepositories.removeAll { finished.contains($0.id) }
                try next.save(to: record)
                configuration = next
            }
        } catch is CancellationError {
        } catch { await handleGitHubFailure(error, operation: "synchronize runners") }
    }

    /// Reconciles one Mac's runners. A Mac without a job limit only removes the runners of unlinked repositories.
    private func reconcile(
        _ provisioner: RunnerProvisioner, capacity: Int?, missingLimit: String,
        repositories: [GitHubRepository], unlinked: [GitHubRepository], token: String
    ) async throws -> [RepositoryRunnerStatus] {
        guard let capacity else {
            let removals = unlinked.isEmpty
                ? [] : try await provisioner.reconcile(repositories: [], unlinked: unlinked, capacity: 0, token: token)
            return Self.unreconciled(repositories, unlinked: [], problem: .failed(missingLimit)) + removals
        }
        return try await provisioner.reconcile(repositories: repositories, unlinked: unlinked, capacity: capacity, token: token)
    }

    /// Reconciles the runners of a Mac that this host manages, with that Mac's job limit.
    private func pairedStatuses(
        of mac: PairedMac, in pairedMacs: PairedMacs,
        repositories: [GitHubRepository], unlinked: [GitHubRepository], token: String
    ) async throws -> [RepositoryRunnerStatus] {
        // A Mac that does not answer keeps its runners until both sides are read again at the next synchronization.
        let report: HostSettingsReport
        do { report = try await pairedMacs.readSettings(of: mac.id) }
        catch { return Self.unreconciled(repositories, unlinked: unlinked, problem: .failed(error.localizedDescription)) }
        guard report.hasLoadedPoolStatus, report.poolError == nil else {
            let message = report.poolError ?? "The Mac has not read its job limit yet."
            return Self.unreconciled(repositories, unlinked: unlinked, problem: .failed(message))
        }
        let provisioner = pairedProvisioners[mac.id] ?? RunnerProvisioner(mac: PairedRunnerMac(id: mac.id, macs: pairedMacs), client: client)
        pairedProvisioners[mac.id] = provisioner
        return try await reconcile(
            provisioner, capacity: report.poolStatus?.configuration.maximumConcurrentJobs,
            missingLimit: "Set Maximum concurrent jobs in its pane under Runners and choose Save to register runners.",
            repositories: repositories, unlinked: unlinked, token: token
        )
    }

    /// Statuses for a Mac whose runners were not reconciled. Nothing on it counts as removed.
    private static func unreconciled(
        _ repositories: [GitHubRepository], unlinked: [GitHubRepository], problem: RunnerProvisioningProblem
    ) -> [RepositoryRunnerStatus] {
        repositories.map {
            RepositoryRunnerStatus(
                repository: $0, desiredCount: 0, registeredCount: 0, onlineCount: 0, busyCount: 0, excessCount: 0,
                problems: [problem]
            )
        } + unlinked.map {
            RepositoryRunnerStatus(
                repository: $0, desiredCount: 0, registeredCount: 0, onlineCount: 0, busyCount: 0, excessCount: 0,
                problems: [problem], isUnlinked: true
            )
        }
    }

    /// Answers the managing host's request to read or change this Mac's runner folders, unless this Mac is
    /// reconciling them or cannot run new runners yet.
    func answer(_ request: RunnerRequest) async -> HostLinkReply {
        switch request {
        case .hostName, .inventory, .markLabelsApplied: break
        case .prepareArchive, .install, .markUnregistering, .markRemoved:
            guard storageIsReady, !isShuttingDown else {
                return .refused("Runner changes wait until storage is ready and the runner host is running.")
            }
        }
        do {
            return try await provisioner.perform { mac in
                switch request {
                case .hostName: return .hostName(try await mac.hostName())
                case .inventory: return .runners(try await mac.runners())
                case .prepareArchive(let download): return .archive(try await mac.prepareArchive(download))
                case .install(let installation): try await mac.install(installation)
                case let .markUnregistering(runner, repositoryID): try await mac.markUnregistering(runner, from: repositoryID)
                case .markRemoved(let runner): try await mac.markRemoved(runner)
                case .markLabelsApplied(let labels): try await mac.markLabelsApplied(labels)
                }
                return .completed
            }
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    private func authenticated<Value>(_ operation: @MainActor (String) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let token = try await authentication.accessToken()
        do { return try await operation(token) }
        catch let error as GitHubError {
            guard case .response(status: 401, message: _) = error else { throw error }
            try Task.checkCancellation()
            let refreshed = try await authentication.accessToken(rejecting: token)
            return try await operation(refreshed)
        }
    }

    private func handleGitHubFailure(_ error: any Error, operation: String) async {
        if let error = error as? GitHubError {
            switch error {
            case .notSignedIn, .response(status: 401, message: _), .authorization:
                account = nil
                if management?.manager == nil { await packageAccess?.stop() }
            default: break
            }
        }
        errorMessage = "Could not \(operation): \(error.localizedDescription)"
    }

    func shutDown() async {
        isShuttingDown = true
        await packageAccess?.stop()
        packageAccess = nil
        cancelConnection()
        synchronizationTask?.cancel()
        await connectionTask?.value
        await synchronizationTask?.value
    }

    private func openBrowser(_ url: URL) throws {
        guard openURL(url) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not open your browser."])
        }
    }
}

extension GitHubHostSettings {
    /// Only a current managed runner can open this connection. The local relay rechecks the grant on each Git request.
    func servePackage(
        _ fetch: PackageFetch, reply: @escaping @Sendable (HostLinkReply) async throws -> Void,
        next: @escaping @Sendable () async throws -> HostLinkRequest
    ) async throws {
        guard management?.manager == nil, PackageFetch.validRepository(fetch.repository),
              try packageRepositories().contains(where: { $0.caseInsensitiveCompare(fetch.repository) == .orderedSame }) else {
            throw HostSettingsError("The host has not allowed this package repository.")
        }
        struct Relay: Decodable { let port: UInt16; let authorization: String }
        let file = installation.packageGitConfiguration.deletingPathExtension().appendingPathExtension("json")
        let relay: Relay
        do { relay = try JSONDecoder().decode(Relay.self, from: Data(contentsOf: file)) }
        catch CocoaError.fileReadNoSuchFile {
            throw HostSettingsError(packageAccessError ?? "Sign in to GitHub on the managing host to fetch private packages.")
        }
        let base = URL(string: "http://127.0.0.1:\(relay.port)")!
        let repository = base.appending(path: fetch.repository + ".git")
        let discovery = fetch.operation == .refs
        let url = discovery ? repository.appending(path: "info/refs").appending(queryItems: [
            URLQueryItem(name: "service", value: "git-upload-pack")
        ]) : repository.appending(path: "git-upload-pack")
        var request = URLRequest(url: url, timeoutInterval: PackageFetch.idleTimeout)
        request.setValue(relay.authorization, forHTTPHeaderField: "Authorization")
        if fetch.protocolV2 { request.setValue("version=2", forHTTPHeaderField: "Git-Protocol") }
        if !discovery {
            request.httpMethod = "POST"
            request.setValue("application/x-git-upload-pack-request", forHTTPHeaderField: "Content-Type")
            if fetch.gzip { request.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
        }
        try await reply(.completed)
        request.httpBody = try await fetch.receiveBody(next: next)
        try await fetch.sendResponse(to: request, reply: reply)
    }
}
