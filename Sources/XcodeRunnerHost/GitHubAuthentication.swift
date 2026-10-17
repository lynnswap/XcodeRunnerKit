import CryptoKit
import Foundation
import Security

struct GitHubDeviceAuthorization: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresAt: Date
    let interval: TimeInterval
}

struct GitHubCredentials: Codable, Sendable {
    let clientID: String
    let account: GitHubAccount
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let refreshExpiresAt: Date?
}

struct GitHubApplicationCredentials: Codable, Sendable {
    let clientID: String
    let clientSecret: String
}

protocol GitHubCredentialStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

struct GitHubKeychainStore: GitHubCredentialStore {
    private let account: String
    private let service = "dev.lynnswap.XcodeRunnerHost.GitHub"

    init(hostRoot: URL, accountSuffix: String = "credentials") {
        account = SHA256.hash(data: Data(hostRoot.standardizedFileURL.path(percentEncoded: false).utf8))
            .map { String(format: "%02x", $0) }.joined() + "." + accountSuffix
    }

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw GitHubError.invalidResponse }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData] = data
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private var baseQuery: [CFString: Any] {
        // The host ships without a provisioning profile for data-protection keychain access groups.
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

actor GitHubAuthentication {
    private let client: GitHubClient
    private let store: any GitHubCredentialStore
    private let appStore: (any GitHubCredentialStore)?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private var generation = 0
    private var refresh: (id: UUID, task: Task<String, any Error>)?

    init(hostRoot: URL, client: GitHubClient = .init()) {
        self.init(
            client: client, store: GitHubKeychainStore(hostRoot: hostRoot),
            appStore: GitHubKeychainStore(hostRoot: hostRoot, accountSuffix: "application")
        )
    }

    init(
        client: GitHubClient, store: any GitHubCredentialStore, appStore: (any GitHubCredentialStore)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.store = store
        self.appStore = appStore
        self.sleep = sleep
        self.now = now
    }

    func begin(clientID: String) async throws -> GitHubDeviceAuthorization {
        try await client.beginDeviceAuthorization(clientID: clientID)
    }

    func saveApp(clientID: String, clientSecret: String) throws {
        guard let appStore else { throw GitHubError.notSignedIn }
        try appStore.write(JSONEncoder().encode(GitHubApplicationCredentials(clientID: clientID, clientSecret: clientSecret)))
        generation += 1
        refresh?.task.cancel()
        refresh = nil
    }

    func appClientID() throws -> String? {
        try applicationCredentials()?.clientID
    }

    func completeWebAuthorization(
        clientID: String, code: String, redirectURI: URL, codeVerifier: String
    ) async throws -> GitHubAccount {
        guard let app = try applicationCredentials(), app.clientID == clientID else { throw GitHubError.notSignedIn }
        let originalGeneration = generation
        let response = try await client.exchangeAuthorizationCode(
            clientID: clientID, clientSecret: app.clientSecret, code: code, redirectURI: redirectURI, codeVerifier: codeVerifier
        )
        let token = try response.validatedAccessToken()
        let account = try await client.currentAccount(accessToken: token)
        try Task.checkCancellation()
        guard generation == originalGeneration else { throw GitHubError.authenticationChanged }
        try save(response: response, account: account, clientID: clientID)
        generation += 1
        return account
    }

    func finish(clientID: String, authorization: GitHubDeviceAuthorization) async throws -> GitHubAccount {
        let originalGeneration = generation
        var interval = authorization.interval
        while now() < authorization.expiresAt {
            try await sleep(interval)
            try Task.checkCancellation()
            guard now() < authorization.expiresAt else { throw GitHubError.deviceAuthorizationExpired }
            let response = try await client.pollDeviceAuthorization(clientID: clientID, deviceCode: authorization.deviceCode)
            switch response.error {
            case "authorization_pending": continue
            case "slow_down":
                interval = response.interval ?? (interval + 5)
                continue
            case "expired_token": throw GitHubError.deviceAuthorizationExpired
            default: break
            }
            let token = try response.validatedAccessToken()
            let account = try await client.currentAccount(accessToken: token)
            try Task.checkCancellation()
            guard generation == originalGeneration else { throw GitHubError.authenticationChanged }
            try save(response: response, account: account, clientID: clientID)
            generation += 1
            return account
        }
        throw GitHubError.deviceAuthorizationExpired
    }

    func account(clientID: String? = nil) throws -> GitHubAccount? {
        guard let credentials = try credentials(), clientID == nil || credentials.clientID == clientID else { return nil }
        return credentials.account
    }

    func accessToken(clientID: String, rejecting rejectedToken: String? = nil) async throws -> String {
        guard let credentials = try credentials(), credentials.clientID == clientID else { throw GitHubError.notSignedIn }
        if rejectedToken != credentials.accessToken,
           credentials.expiresAt == nil || credentials.expiresAt! > now().addingTimeInterval(60) {
            return credentials.accessToken
        }
        guard let refreshToken = credentials.refreshToken,
              credentials.refreshExpiresAt == nil || credentials.refreshExpiresAt! > now() else {
            throw GitHubError.notSignedIn
        }
        let originalGeneration = generation
        let pending: Task<String, any Error>
        if let refresh {
            pending = refresh.task
        } else {
            let app = try applicationCredentials()
            let clientSecret = app?.clientID == clientID ? app?.clientSecret : nil
            let id = UUID()
            pending = Task {
                defer { if refresh?.id == id { refresh = nil } }
                let response = try await client.refreshToken(
                    clientID: clientID, clientSecret: clientSecret, refreshToken: refreshToken
                )
                guard generation == originalGeneration else { throw GitHubError.authenticationChanged }
                let token = try response.validatedAccessToken()
                try save(response: response, account: credentials.account, clientID: clientID)
                return token
            }
            refresh = (id, pending)
        }
        let token = try await pending.value
        guard generation == originalGeneration else { throw GitHubError.authenticationChanged }
        try Task.checkCancellation()
        return token
    }

    func signOut() throws {
        generation += 1
        refresh?.task.cancel()
        refresh = nil
        try store.remove()
    }

    private func credentials() throws -> GitHubCredentials? {
        try store.read().map { try JSONDecoder().decode(GitHubCredentials.self, from: $0) }
    }

    private func applicationCredentials() throws -> GitHubApplicationCredentials? {
        try appStore?.read().map { try JSONDecoder().decode(GitHubApplicationCredentials.self, from: $0) }
    }

    private func save(response: GitHubTokenResponse, account: GitHubAccount, clientID: String) throws {
        let receivedAt = now()
        let credentials = GitHubCredentials(
            clientID: clientID, account: account, accessToken: try response.validatedAccessToken(),
            refreshToken: response.refreshToken, expiresAt: response.expiresIn.map { receivedAt.addingTimeInterval($0) },
            refreshExpiresAt: response.refreshTokenExpiresIn.map { receivedAt.addingTimeInterval($0) }
        )
        try store.write(JSONEncoder().encode(credentials))
    }
}
