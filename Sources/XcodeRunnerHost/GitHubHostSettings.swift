import AppKit
import CryptoKit
import Foundation
import Observation
import XcodeRunnerKit

struct GitHubHostConfiguration: Codable, Equatable {
    var clientID = ""
    var appSlug = ""
    var callbackURL: URL?
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
    private let record: URL
    private let authentication: GitHubAuthentication
    private let client: GitHubClient
    private let provisioner: RunnerProvisioner
    private let pool: HostExecutionPool
    private var configuration = GitHubHostConfiguration()
    private var connectionTask: Task<Void, Never>?
    private var synchronizationTask: Task<Void, Never>?
    private var browserCallback: GitHubBrowserCallback?
    private var registration: GitHubAppRegistration?
    private var pendingApp: CreatedGitHubApp?
    var clientIDInput = ""
    var appSlugInput = ""
    var organizationInput = ""
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
    var storageIsReady = false

    var hasPendingApp: Bool { pendingApp != nil }

    init(
        installation: HostInstallation, pool: HostExecutionPool, client: GitHubClient = .init(),
        authentication: GitHubAuthentication? = nil, provisioner: RunnerProvisioner? = nil
    ) {
        self.pool = pool
        self.client = client
        self.record = installation.hostRoot.appending(path: "github-host.json")
        self.authentication = authentication ?? GitHubAuthentication(hostRoot: installation.hostRoot, client: client)
        self.provisioner = provisioner ?? RunnerProvisioner(
            installation: installation,
            installerURL: Bundle.main.bundleURL.appending(path: "Contents/Resources/HostSetup/install-github-runner.sh"),
            client: client
        )
        do {
            configuration = try GitHubHostConfiguration.load(from: record)
            clientIDInput = configuration.clientID
            appSlugInput = configuration.appSlug
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
        guard !configuration.clientID.isEmpty else { return }
        do {
            account = try await authentication.account(clientID: configuration.clientID)
            if account != nil { await loadRepositories() }
        } catch {
            errorMessage = "Could not access GitHub credentials: \(error.localizedDescription)"
        }
    }

    func createApp() {
        guard !isConnecting, !isSynchronizing else { return }
        isConnecting = true
        errorMessage = nil
        connectionTask = Task {
            defer { finishConnecting() }
            do {
                let registration = try await GitHubAppSetup().begin(organization: organizationInput)
                self.registration = registration
                try openBrowser(registration.startURL)
                let app = try await registration.complete()
                try Task.checkCancellation()
                try await storeCreatedApp(app)
                installApp()
            } catch is CancellationError {
            } catch {
                errorMessage = pendingApp == nil
                    ? "Could not set up the GitHub App: \(error.localizedDescription)"
                    : "The app was created on GitHub, but its settings could not be saved. Retry saving: \(error.localizedDescription)"
            }
        }
    }

    func retrySavingApp() {
        guard pendingApp != nil, !isConnecting, !isSynchronizing else { return }
        isConnecting = true
        errorMessage = nil
        connectionTask = Task {
            defer { finishConnecting() }
            do {
                try await saveCreatedApp()
                installApp()
            }
            catch { errorMessage = "The app is already created. Its settings still need to be saved: \(error.localizedDescription)" }
        }
    }

    func storeCreatedApp(_ app: CreatedGitHubApp) async throws {
        pendingApp = app
        try await saveCreatedApp()
    }

    private func saveCreatedApp() async throws {
        guard let app = pendingApp else { return }
        try await authentication.saveApp(clientID: app.clientID, clientSecret: app.clientSecret)
        configuration = GitHubHostConfiguration(clientID: app.clientID, appSlug: app.slug, callbackURL: app.callbackURL)
        clientIDInput = app.clientID
        appSlugInput = app.slug
        account = nil
        repositories = []
        runnerStatuses = []
        selectedRepositoryIDs = []
        try configuration.save(to: record)
        pendingApp = nil
    }

    func installApp() {
        let slug = appSlugInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else {
            errorMessage = "Create a GitHub App first, or enter its app slug."
            return
        }
        var components = URLComponents(string: "https://github.com/apps/")!
        components.path = "/apps/\(slug)/installations/new"
        do { try openBrowser(try requireURL(components.url)) }
        catch { errorMessage = error.localizedDescription }
    }

    func signIn() {
        guard !isConnecting, !isSynchronizing else { return }
        let clientID = clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            errorMessage = "Create a GitHub App first, or enter an existing app's Client ID."
            return
        }
        isConnecting = true
        errorMessage = nil
        connectionTask = Task {
            defer { finishConnecting() }
            do {
                if configuration.clientID != clientID {
                    configuration = GitHubHostConfiguration(clientID: clientID, appSlug: appSlugInput)
                    selectedRepositoryIDs = []
                    repositories = []
                    runnerStatuses = []
                    account = nil
                }
                configuration.appSlug = appSlugInput.trimmingCharacters(in: .whitespacesAndNewlines)
                try configuration.save(to: record)
                if let callbackURL = configuration.callbackURL {
                    let callback = try await GitHubBrowserCallback.start(callbackURL: callbackURL)
                    browserCallback = callback
                    let verifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                    var url = URLComponents(string: "https://github.com/login/oauth/authorize")!
                    url.queryItems = [
                        URLQueryItem(name: "client_id", value: clientID),
                        URLQueryItem(name: "redirect_uri", value: callback.callbackURL.absoluteString),
                        URLQueryItem(name: "state", value: callback.state),
                        URLQueryItem(name: "code_challenge", value: challenge),
                        URLQueryItem(name: "code_challenge_method", value: "S256"),
                        URLQueryItem(name: "scope", value: "offline_access"),
                    ]
                    try openBrowser(try requireURL(url.url))
                    let code = try await callback.waitForCode()
                    account = try await authentication.completeWebAuthorization(
                        clientID: clientID, code: code, redirectURI: callback.callbackURL, codeVerifier: verifier
                    )
                } else {
                    let authorization = try await authentication.begin(clientID: clientID)
                    deviceAuthorization = authorization
                    try openBrowser(authorization.verificationURI)
                    account = try await authentication.finish(clientID: clientID, authorization: authorization)
                }
                try Task.checkCancellation()
                await loadRepositories()
            } catch is CancellationError {
            } catch {
                errorMessage = "Could not sign in to GitHub: \(error.localizedDescription)"
            }
        }
    }

    func cancelConnection() {
        connectionTask?.cancel()
        browserCallback?.cancel()
        registration?.cancel()
    }

    private func finishConnecting() {
        browserCallback?.cancel()
        registration?.cancel()
        browserCallback = nil
        registration = nil
        deviceAuthorization = nil
        connectionTask = nil
        isConnecting = false
    }

    func signOut() async {
        guard !isConnecting, !isSynchronizing else { return }
        do {
            try await authentication.signOut()
            account = nil
            repositories = []
            runnerStatuses = []
            errorMessage = nil
        } catch { errorMessage = "Could not disconnect GitHub: \(error.localizedDescription)" }
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

    func saveSelection() throws {
        var available: [Int: GitHubRepository] = [:]
        for repository in configuration.repositories + repositories { available[repository.id] = repository }
        var next = configuration
        next.repositories = try selectedRepositoryIDs.sorted().map { id in
            guard let repository = available[id] else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Reload repositories before applying their selection."])
            }
            return repository
        }
        try next.save(to: record)
        configuration = next
    }

    func synchronize() async {
        guard synchronizationTask == nil else { return }
        let task = Task { await performSynchronization() }
        synchronizationTask = task
        await task.value
        synchronizationTask = nil
    }

    private func performSynchronization() async {
        guard storageIsReady, !isConnecting, !isSynchronizing else { return }
        guard !configuration.repositories.isEmpty else { runnerStatuses = []; return }
        guard account != nil else {
            errorMessage = "Sign in to synchronize runner registrations. Existing jobs continue using the saved execution limit."
            return
        }
        isSynchronizing = true
        defer { isSynchronizing = false }
        do {
            guard let status = try await pool.status() else { return }
            let selected = configuration.repositories
            runnerStatuses = try await authenticated { token in
                let available = try await client.listRepositories(accessToken: token)
                repositories = available
                let current = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
                let statuses = await provisioner.reconcile(
                    repositories: selected.compactMap { current[$0.id] }, capacity: status.maximumConcurrentJobs, token: token
                ) + selected.filter { current[$0.id] == nil }.map { repository in
                    RepositoryRunnerStatus(
                        repository: repository, desiredCount: status.maximumConcurrentJobs,
                        registeredCount: 0, onlineCount: 0, busyCount: 0, excessCount: 0,
                        errorMessage: "This repository is no longer accessible to the GitHub App. Check its installation and permissions, then reload repositories.",
                        requiresAuthentication: false
                    )
                }
                runnerStatuses = statuses
                if statuses.contains(where: \.requiresAuthentication) {
                    throw GitHubError.response(status: 401, message: "The runner management token was rejected.")
                }
                return statuses
            }
            errorMessage = nil
        } catch is CancellationError {
        } catch { handleGitHubFailure(error, operation: "synchronize runners") }
    }

    private func authenticated<Value>(_ operation: @MainActor (String) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let token = try await authentication.accessToken(clientID: configuration.clientID)
        do { return try await operation(token) }
        catch let error as GitHubError {
            guard case .response(status: 401, message: _) = error else { throw error }
            try Task.checkCancellation()
            let refreshed = try await authentication.accessToken(clientID: configuration.clientID, rejecting: token)
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
        cancelConnection()
        synchronizationTask?.cancel()
        await connectionTask?.value
        await synchronizationTask?.value
    }

    private func openBrowser(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not open your browser."])
        }
    }

    private func requireURL(_ url: URL?) throws -> URL {
        guard let url else { throw URLError(.badURL) }
        return url
    }
}
