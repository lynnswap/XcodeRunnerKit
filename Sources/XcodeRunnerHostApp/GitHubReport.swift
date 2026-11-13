import Foundation

/// One repository's runners on a host and the Macs it manages, as Overview shows them.
struct RepositoryRunnerReport: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let fullName: String
    let desiredCount: Int
    let registeredCount: Int
    let onlineCount: Int
    let busyCount: Int
    let excessCount: Int
    let errorMessage: String?
    /// Whether the repository left the selection, so `registeredCount` counts the runners still to remove.
    let isUnlinked: Bool

    init(_ status: RepositoryRunnerStatus) {
        id = status.id
        fullName = status.repository.fullName
        desiredCount = status.desiredCount
        registeredCount = status.registeredCount
        onlineCount = status.onlineCount
        busyCount = status.busyCount
        excessCount = status.excessCount
        errorMessage = status.errorMessage
        isUnlinked = status.isUnlinked
    }
}

/// A host's GitHub sign-in, repository selection, and runner counts, as its own window shows them and as it sends
/// them to a dashboard. It holds neither a token nor the device code that completes a sign-in.
struct GitHubReport: Codable, Equatable, Sendable {
    /// What the person enters on GitHub's page while the host waits for the sign-in.
    struct SignInCode: Codable, Equatable, Sendable {
        let userCode: String
        let verificationURI: URL
    }

    let accountLogin: String?
    let hasRestored: Bool
    let isConnecting: Bool
    let signInCode: SignInCode?
    let isBusy: Bool
    let canReloadRepositories: Bool
    let canDisconnect: Bool
    let isLoadingRepositories: Bool
    let isSavingSelection: Bool
    let isSynchronizing: Bool
    /// The repositories that can be selected: the saved ones and the ones that GitHub lists.
    let selectableRepositories: [GitHubRepository]
    /// Whether GitHub listed a repository that the app is installed on.
    let hasListedRepositories: Bool
    let savedRepositoryIDs: Set<Int>
    let runnerStatuses: [RepositoryRunnerReport]
    let errorMessage: String?
    /// The page where the person installs the GitHub App on repositories.
    let installationURL: URL
    /// The Mac that manages the host and registers its runners in its place.
    let managerName: String?
    let managesMacs: Bool
}
