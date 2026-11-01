import Foundation

struct GitHubRepository: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
    }
}

struct GitHubAccount: Codable, Equatable, Sendable {
    let id: Int
    let login: String
}

struct GitHubRunnerLabel: Codable, Equatable, Sendable {
    let name: String
}

struct GitHubRunner: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    let status: String
    let busy: Bool
    let labels: [GitHubRunnerLabel]
}

struct GitHubRunnerDownload: Sendable {
    let filename: String
    let downloadURL: URL
    let sha256Checksum: String
}

enum GitHubError: LocalizedError {
    case invalidResponse
    case response(status: Int, message: String)
    case authorization(code: String, description: String?)
    case deviceAuthorizationExpired
    case notSignedIn
    case authenticationChanged
    case missingRunnerDownload

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned an invalid response."
        case let .response(status, message):
            "GitHub request failed (HTTP \(status)): \(message)"
        case let .authorization(code, description):
            "GitHub authorization failed: \(description ?? code)"
        case .deviceAuthorizationExpired:
            "The GitHub sign-in code expired. Sign in again."
        case .notSignedIn:
            "Sign in to GitHub to manage repository runners."
        case .authenticationChanged:
            "The GitHub account changed during this operation. Try again."
        case .missingRunnerDownload:
            "The official runner release has no macOS ARM64 archive with a SHA-256 checksum."
        }
    }
}

struct GitHubClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        transport = { try await session.data(for: $0) }
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    func listRepositories(accessToken: String) async throws -> [GitHubRepository] {
        struct Installation: Decodable { let id: Int }
        struct Installations: Decodable { let installations: [Installation] }
        struct Repositories: Decodable { let repositories: [GitHubRepository] }
        let installations: [Installation] = try await pages(path: "user/installations", accessToken: accessToken) {
            try JSONDecoder().decode(Installations.self, from: $0).installations
        }
        var repositories: [Int: GitHubRepository] = [:]
        for installation in installations {
            let installed: [GitHubRepository] = try await pages(
                path: "user/installations/\(installation.id)/repositories", accessToken: accessToken
            ) { try JSONDecoder().decode(Repositories.self, from: $0).repositories }
            for repository in installed { repositories[repository.id] = repository }
        }
        return repositories.values.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    func listRunners(repository: GitHubRepository, accessToken: String) async throws -> [GitHubRunner] {
        struct Runners: Decodable { let runners: [GitHubRunner] }
        return try await pages(path: "repos/\(repository.fullName)/actions/runners", accessToken: accessToken) {
            try JSONDecoder().decode(Runners.self, from: $0).runners
        }
    }

    func repository(fullName: String, accessToken: String) async throws -> GitHubRepository {
        try await api(path: "repos/\(fullName)", accessToken: accessToken)
    }

    func registrationToken(repository: GitHubRepository, accessToken: String) async throws -> String {
        struct Token: Decodable { let token: String }
        let result: Token = try await api(
            path: "repos/\(repository.fullName)/actions/runners/registration-token", method: "POST", accessToken: accessToken
        )
        return result.token
    }

    func runnerDownload(accessToken: String) async throws -> GitHubRunnerDownload {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let digest: String?
            enum CodingKeys: String, CodingKey {
                case name, digest
                case browserDownloadURL = "browser_download_url"
            }
        }
        struct Release: Decodable { let assets: [Asset] }
        // This public download must not require Contents permission on an unrelated repository.
        let release: Release = try await api(path: "repos/actions/runner/releases/latest", accessToken: nil)
        guard let asset = release.assets.first(where: {
            $0.name.hasPrefix("actions-runner-osx-arm64-") && $0.name.hasSuffix(".tar.gz")
        }), let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw GitHubError.missingRunnerDownload
        }
        let checksum = String(digest.dropFirst("sha256:".count))
        guard checksum.count == 64, checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GitHubError.missingRunnerDownload
        }
        return GitHubRunnerDownload(filename: asset.name, downloadURL: asset.browserDownloadURL, sha256Checksum: checksum)
    }

    func currentAccount(accessToken: String) async throws -> GitHubAccount {
        try await api(path: "user", accessToken: accessToken)
    }

    func beginDeviceAuthorization(clientID: String) async throws -> GitHubDeviceAuthorization {
        struct Response: Decodable {
            let deviceCode: String?
            let userCode: String?
            let verificationURI: URL?
            let expiresIn: TimeInterval?
            let interval: TimeInterval?
            let error: String?
            let errorDescription: String?
            enum CodingKeys: String, CodingKey {
                case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
                case expiresIn = "expires_in", interval, error, errorDescription = "error_description"
            }
        }
        let response: Response = try await oauth(
            path: "login/device/code", values: ["client_id": clientID, "scope": "offline_access"]
        )
        if let error = response.error { throw GitHubError.authorization(code: error, description: response.errorDescription) }
        guard let deviceCode = response.deviceCode, let userCode = response.userCode,
              let verificationURI = response.verificationURI, let expiresIn = response.expiresIn,
              let interval = response.interval else { throw GitHubError.invalidResponse }
        return GitHubDeviceAuthorization(
            deviceCode: deviceCode, userCode: userCode, verificationURI: verificationURI,
            expiresAt: Date().addingTimeInterval(expiresIn), interval: interval
        )
    }

    func pollDeviceAuthorization(clientID: String, deviceCode: String) async throws -> GitHubTokenResponse {
        try await oauth(path: "login/oauth/access_token", values: [
            "client_id": clientID, "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
    }

    func refreshToken(clientID: String, clientSecret: String? = nil, refreshToken: String) async throws -> GitHubTokenResponse {
        var values = [
            "client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token",
        ]
        values["client_secret"] = clientSecret
        return try await oauth(path: "login/oauth/access_token", values: values)
    }

    func exchangeAuthorizationCode(
        clientID: String, clientSecret: String, code: String, redirectURI: URL, codeVerifier: String
    ) async throws -> GitHubTokenResponse {
        try await oauth(path: "login/oauth/access_token", values: [
            "client_id": clientID, "client_secret": clientSecret, "code": code,
            "redirect_uri": redirectURI.absoluteString, "code_verifier": codeVerifier,
        ])
    }

    private func pages<Element: Sendable>(
        path: String, accessToken: String, decode: (Data) throws -> [Element]
    ) async throws -> [Element] {
        var all: [Element] = []
        var page = 1
        while true {
            var components = URLComponents(url: URL(string: "https://api.github.com/")!.appending(path: path), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
            let (data, response) = try await request(apiRequest(url: components.url!, accessToken: accessToken))
            all.append(contentsOf: try decode(data))
            guard response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true else { return all }
            page += 1
        }
    }

    private func api<Result: Decodable>(path: String, method: String = "GET", accessToken: String?) async throws -> Result {
        var request = apiRequest(url: URL(string: "https://api.github.com/")!.appending(path: path), accessToken: accessToken)
        request.httpMethod = method
        return try JSONDecoder().decode(Result.self, from: await self.request(request).0)
    }

    private func apiRequest(url: URL, accessToken: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("XcodeRunnerHost", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func oauth<Result: Decodable>(path: String, values: [String: String]) async throws -> Result {
        var request = URLRequest(url: URL(string: "https://github.com/")!.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XcodeRunnerHost", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return try JSONDecoder().decode(Result.self, from: await self.request(request).0)
    }

    private func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let message: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data).message) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw GitHubError.response(status: response.statusCode, message: message)
        }
        return (data, response)
    }
}

struct GitHubTokenResponse: Decodable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let refreshTokenExpiresIn: TimeInterval?
    let error: String?
    let errorDescription: String?
    let interval: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in", error, errorDescription = "error_description", interval
    }

    func validatedAccessToken() throws -> String {
        if let error { throw GitHubError.authorization(code: error, description: errorDescription) }
        guard let accessToken else { throw GitHubError.invalidResponse }
        return accessToken
    }
}
