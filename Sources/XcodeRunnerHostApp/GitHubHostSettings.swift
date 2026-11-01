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
    private let record: URL
    private let authentication: GitHubAuthentication
    private let client: GitHubClient
    private let provisioner: RunnerProvisioner
    private let pool: HostExecutionPool
    private let openURL: @MainActor (URL) -> Bool
    /// The Macs that this host manages. They register runners for the same repositories as this Mac.
    @ObservationIgnored weak var pairedMacs: ManagedMacs?
    /// This Mac's pairing with a managing host, which then registers this Mac's runners instead.
    @ObservationIgnored weak var management: HostManagement?
    private var pairedProvisioners: [HostPairing.ID: RunnerProvisioner] = [:]
    private var configuration = GitHubHostConfiguration()
    private var connectionTask: Task<Void, Never>?
    private var synchronizationTask: Task<Void, Never>?
    var selectedRepositoryIDs: Set<Int> = []
    private(set) var account: GitHubAccount?
    private(set) var repositories: [GitHubRepository] = []
    private(set) var runnerStatuses: [RepositoryRunnerStatus] = []
    private(set) var deviceAuthorization: GitHubDeviceAuthorization?
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

    func installApp() {
        do { try openBrowser(app.installationURL) }
        catch { errorMessage = error.localizedDescription }
    }

    func signIn() {
        guard !isBusy else { return }
        isConnecting = true
        errorMessage = nil
        connectionTask = Task {
            defer { finishConnecting() }
            do {
                let authorization = try await authentication.begin()
                deviceAuthorization = authorization
                try openBrowser(authorization.verificationURI)
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

    func signOut() async {
        guard canDisconnect else { return }
        do {
            try await authentication.signOut()
            account = nil
            repositories = []
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
        do {
            repositories = try await authenticated { token in
                try await client.listRepositories(accessToken: token)
            }
            errorMessage = nil
        } catch is CancellationError {
        } catch { handleGitHubFailure(error, operation: "load repositories") }
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
        guard !isShuttingDown else { throw HostSettingsError("The runner host is stopping.") }
        guard !isBusy, !isLoadingRepositories else {
            throw HostSettingsError("GitHub runner management is busy. Retry after the current operation finishes.")
        }
        isSavingSelection = true
        defer { isSavingSelection = false }
        try saveSelection(selectedIDs)
        return await applySavedRepositorySelection()
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

    func applyRepositorySelection() async {
        do {
            errorMessage = try await updateRepositorySelection(selectedRepositoryIDs)
        } catch { errorMessage = "Could not save the repository selection: \(error.localizedDescription)" }
    }

    /// Registers the selected repositories' runners on this Mac and the Macs it manages, and removes the runners of
    /// repositories that left the selection.
    func synchronize() async {
        guard synchronizationTask == nil, storageIsReady, !isConnecting else { return }
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
                let available = try await client.listRepositories(accessToken: token)
                repositories = available
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
                        missingLimit: "Set Maximum concurrent jobs for this Mac under Runners and choose Apply to register runners.",
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
            errorMessage = nil
            let finished = Set(statuses.filter(\.hasFinishedRemoval).map(\.id))
            if !finished.isEmpty {
                var next = configuration
                next.unlinkedRepositories.removeAll { finished.contains($0.id) }
                try next.save(to: record)
                configuration = next
            }
        } catch is CancellationError {
        } catch { handleGitHubFailure(error, operation: "synchronize runners") }
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
        of mac: ManagedMac, in pairedMacs: ManagedMacs,
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
            missingLimit: "Set Maximum concurrent jobs in its pane under Runners and choose Apply to register runners.",
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
        case .hostName, .inventory: break
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

    private func handleGitHubFailure(_ error: any Error, operation: String) {
        if let error = error as? GitHubError {
            switch error {
            case .notSignedIn, .response(status: 401, message: _), .authorization:
                account = nil
            default: break
            }
        }
        errorMessage = "Could not \(operation): \(error.localizedDescription)"
    }

    func shutDown() async {
        isShuttingDown = true
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
