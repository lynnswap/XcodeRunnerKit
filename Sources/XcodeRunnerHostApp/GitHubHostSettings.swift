import AppKit
import Foundation
import Observation
import XcodeRunnerHostSupport
import XcodeRunnerKit

struct GitHubHostConfiguration: Codable, Equatable {
    var repositories: [GitHubRepository] = []

    static func load(from url: URL) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Self() }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
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
        if configuration.repositories.isEmpty {
            runnerStatuses = []
            errorMessage = nil
            return nil
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

    func synchronize() async {
        guard synchronizationTask == nil, storageIsReady, !isConnecting else { return }
        guard !configuration.repositories.isEmpty else { runnerStatuses = []; return }
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
            guard let status = try await pool.status() else {
                errorMessage = "Set Maximum concurrent Xcode jobs under Xcode Execution and choose Apply to register runners."
                return
            }
            let selected = configuration.repositories
            runnerStatuses = try await authenticated { token in
                let available = try await client.listRepositories(accessToken: token)
                repositories = available
                let current = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
                let inaccessible = selected.filter { current[$0.id] == nil }.map { repository in
                    RepositoryRunnerStatus(
                        repository: repository, desiredCount: status.configuration.maximumConcurrentJobs,
                        registeredCount: 0, onlineCount: 0, busyCount: 0, excessCount: 0, problems: [.repositoryInaccessible]
                    )
                }
                do {
                    return try await provisioner.reconcile(
                        repositories: selected.compactMap { current[$0.id] }, capacity: status.configuration.maximumConcurrentJobs, token: token
                    ) + inaccessible
                } catch let failure as RunnerProvisioningAuthenticationFailure {
                    // Keep the latest counts visible while the token is refreshed or the user signs in again.
                    runnerStatuses = failure.statuses + inaccessible
                    throw failure.underlyingError
                }
            }
            errorMessage = nil
        } catch is CancellationError {
        } catch { handleGitHubFailure(error, operation: "synchronize runners") }
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
