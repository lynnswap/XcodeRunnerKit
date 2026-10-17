import Foundation
import Network

struct CreatedGitHubApp: Sendable {
    let clientID: String
    let slug: String
    let clientSecret: String
    let callbackURL: URL
}

struct GitHubAppSetup: Sendable {
    private let transport: GitHubClient.Transport

    init(session: URLSession = .shared) {
        transport = { try await session.data(for: $0) }
    }

    init(transport: @escaping GitHubClient.Transport) {
        self.transport = transport
    }

    @MainActor
    func begin(name: String? = nil, organization: String? = nil) async throws -> GitHubAppRegistration {
        let callback = try await GitHubBrowserCallback.start()
        do {
            let homepage = "https://github.com/lynnswap/XcodeRunnerKit"
            var manifest: [String: Any] = [
                "url": homepage,
                "hook_attributes": ["url": homepage, "active": false],
                "redirect_url": callback.callbackURL.absoluteString,
                "callback_urls": [callback.callbackURL.absoluteString],
                "public": false,
                "default_permissions": ["administration": "write", "metadata": "read"],
                "default_events": [],
                "request_oauth_on_install": false,
            ]
            if let name { manifest["name"] = name }
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            let json = String(decoding: data, as: UTF8.self)
            let organization = organization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let owner = organization.isEmpty ? URL(string: "https://github.com")!
                : URL(string: "https://github.com/organizations")!.appending(component: organization)
            var destination = URLComponents(url: owner.appending(path: "settings/apps/new"), resolvingAgainstBaseURL: false)!
            destination.queryItems = [URLQueryItem(name: "state", value: callback.state)]
            callback.setStartPage("""
                <!doctype html><html lang="en"><meta charset="utf-8">
                <title>Create GitHub App</title>
                <form id="registration" method="post" action="\(Self.escapeHTML(destination.string!))">
                <input type="hidden" name="manifest" value="\(Self.escapeHTML(json))">
                <button type="submit">Create GitHub App on GitHub</button></form>
                <script>document.getElementById('registration').submit();</script></html>
                """)
            return GitHubAppRegistration(callback: callback, transport: transport)
        } catch {
            callback.cancel()
            throw error
        }
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

@MainActor
final class GitHubAppRegistration {
    private let callback: GitHubBrowserCallback
    private let transport: GitHubClient.Transport

    var startURL: URL { callback.startURL }
    var callbackURL: URL { callback.callbackURL }

    fileprivate init(callback: GitHubBrowserCallback, transport: @escaping GitHubClient.Transport) {
        self.callback = callback
        self.transport = transport
    }

    func complete() async throws -> CreatedGitHubApp {
        let code = try await callback.waitForCode()
        try Task.checkCancellation()
        let url = URL(string: "https://api.github.com/app-manifests")!
            .appending(component: code).appending(path: "conversions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        guard response.statusCode == 201 else {
            struct Failure: Decodable { let message: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data).message) ?? "App registration failed."
            throw GitHubError.response(status: response.statusCode, message: message)
        }
        struct App: Decodable {
            let clientID: String
            let slug: String
            let clientSecret: String

            enum CodingKeys: String, CodingKey {
                case clientID = "client_id"
                case slug
                case clientSecret = "client_secret"
            }
        }
        let app = try JSONDecoder().decode(App.self, from: data)
        return CreatedGitHubApp(clientID: app.clientID, slug: app.slug,
                                clientSecret: app.clientSecret, callbackURL: callback.callbackURL)
    }

    func cancel() { callback.cancel() }
}

enum GitHubBrowserCallbackError: LocalizedError {
    case invalidCallbackURL
    case invalidState
    case missingCode

    var errorDescription: String? {
        switch self {
        case .invalidCallbackURL:
            "The GitHub callback must use http://127.0.0.1 with a local port and the /callback path."
        case .invalidState:
            "The GitHub callback did not match this authorization request. Try again."
        case .missingCode:
            "GitHub did not return an authorization code. Try again."
        }
    }
}

@MainActor
final class GitHubBrowserCallback {
    let state = UUID().uuidString
    private(set) var callbackURL: URL
    var startURL: URL { callbackURL.deletingLastPathComponent().appending(path: "start") }

    private let listener: NWListener
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var codeContinuation: CheckedContinuation<String, any Error>?
    private var result: Result<String, any Error>?
    private var listenerStopped = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startPage: String?

    private init(listener: NWListener, callbackURL: URL) {
        self.listener = listener
        self.callbackURL = callbackURL
    }

    static func start(callbackURL: URL? = nil) async throws -> GitHubBrowserCallback {
        let port: NWEndpoint.Port
        if let callbackURL {
            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  components.scheme == "http", components.host == "127.0.0.1",
                  components.path == "/callback", components.query == nil, components.fragment == nil,
                  components.user == nil, components.password == nil,
                  let number = components.port, let raw = UInt16(exactly: number), raw > 0,
                  let requestedPort = NWEndpoint.Port(rawValue: raw) else {
                throw GitHubBrowserCallbackError.invalidCallbackURL
            }
            port = requestedPort
        } else {
            port = .any
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        let server = GitHubBrowserCallback(
            listener: listener, callbackURL: callbackURL ?? URL(string: "http://127.0.0.1:0/callback")!
        )
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                server.readyContinuation = continuation
                listener.stateUpdateHandler = { [weak server] state in
                    Task { @MainActor in server?.listenerChanged(state) }
                }
                listener.newConnectionHandler = { [weak server] connection in
                    Task { @MainActor in
                        guard let server else { connection.cancel(); return }
                        server.accept(connection)
                    }
                }
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in server.cancel() }
        }
        if Task.isCancelled {
            server.cancel()
            throw CancellationError()
        }
        guard let boundPort = listener.port else {
            server.cancel()
            throw GitHubBrowserCallbackError.invalidCallbackURL
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(boundPort.rawValue)
        components.path = "/callback"
        guard let url = components.url else {
            server.cancel()
            throw GitHubBrowserCallbackError.invalidCallbackURL
        }
        server.callbackURL = url
        return server
    }

    func waitForCode() async throws -> String {
        let code = try await withTaskCancellationHandler {
            if Task.isCancelled { cancel() }
            if let result, listenerStopped { return try result.get() }
            return try await withCheckedThrowingContinuation { codeContinuation = $0 }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        try Task.checkCancellation()
        return code
    }

    func cancel() { finish(.failure(CancellationError())) }

    fileprivate func setStartPage(_ html: String) { startPage = html }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            readyContinuation?.resume()
            readyContinuation = nil
        case let .failed(error), let .waiting(error):
            finish(.failure(error))
        case .cancelled:
            listenerStopped = true
            resumeContinuations()
        default:
            break
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func resumeContinuations() {
        guard let result else { return }
        if let readyContinuation {
            self.readyContinuation = nil
            switch result {
            case .success: readyContinuation.resume()
            case let .failure(error): readyContinuation.resume(throwing: error)
            }
        }
        codeContinuation?.resume(with: result)
        codeContinuation = nil
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, bytes: Data())
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.result == nil else { connection.cancel(); return }
                var bytes = bytes
                if let data { bytes.append(data) }
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(connection, request: bytes)
                } else if error != nil || complete || bytes.count >= 65_536 {
                    connection.cancel()
                    self.connections.removeValue(forKey: ObjectIdentifier(connection))
                } else {
                    self.receive(connection, bytes: bytes)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        let expectedHost = "127.0.0.1:\(callbackURL.port!)"
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"),
              lines.dropFirst().contains(where: { $0.lowercased() == "host: \(expectedHost)" }),
              let components = URLComponents(string: String(parts[1])) else {
            send(connection, status: "400 Bad Request", body: "Invalid callback request.")
            return
        }
        if components.path == "/start", let startPage {
            send(connection, status: "200 OK", body: startPage)
        } else if components.path == "/callback" {
            let items = components.queryItems ?? []
            let outcome: Result<String, any Error>
            if items.first(where: { $0.name == "state" })?.value != state {
                outcome = .failure(GitHubBrowserCallbackError.invalidState)
            } else if let error = items.first(where: { $0.name == "error" })?.value {
                outcome = .failure(GitHubError.authorization(code: error, description: nil))
            } else if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                outcome = .success(code)
            } else {
                outcome = .failure(GitHubBrowserCallbackError.missingCode)
            }
            let succeeded = (try? outcome.get()) != nil
            send(connection, status: succeeded ? "200 OK" : "400 Bad Request",
                 body: succeeded ? "GitHub authorization received. You can return to XcodeRunnerHost."
                    : "GitHub authorization failed. Return to XcodeRunnerHost and try again.") {
                self.finish(outcome)
            }
        } else {
            send(connection, status: "404 Not Found", body: "Not found.")
        }
    }

    private func send(_ connection: NWConnection, status: String, body: String,
                      completion: (@MainActor () -> Void)? = nil) {
        let content = Data(body.utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(content)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                completion?()
            }
        })
    }
}
