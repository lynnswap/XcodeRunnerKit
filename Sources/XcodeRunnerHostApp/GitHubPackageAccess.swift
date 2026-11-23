import Darwin
import Foundation
import Network
import XcodeRunnerHostSupport

/// Keeps the GitHub user token inside the host and its bundled read-only Git relay.
actor GitHubPackageAccess {
    private let installation: HostInstallation
    private var config: URL { installation.packageGitConfiguration }
    private let authentication: GitHubAuthentication
    private var requests: Task<Void, Never>?
    private var process: Process?
    private var activeManager: UUID?
    private var input: FileHandle?
    private var acknowledgment: FileHandle?

    init(installation: HostInstallation, authentication: GitHubAuthentication) {
        self.authentication = authentication
        self.installation = installation
    }

    static func repositories(in file: URL) throws -> [String] {
        do { return try JSONDecoder().decode([String].self, from: Data(contentsOf: file)) }
        catch CocoaError.fileReadNoSuchFile { return [] }
    }

    struct Relay: Sendable {
        let process: Process
        let repositories: [String]

        var routing: PackageRouting {
            process.isRunning ? .applied(repositories) : .failed("The private package relay stopped.")
        }
    }

    @discardableResult
    func update(manager: UUID? = nil, repositories: [String]? = nil) throws -> Relay? {
        // Installation access may include repositories that the owner never intended CI jobs to read.
        let allowed = try repositories ?? Self.repositories(in: installation.packageRepositories)
        // GitHub evaluates repository access on every fetch, independently of listing installations.
        let names = Set(allowed)
        guard !names.isEmpty else { stop(); return nil }
        if process?.isRunning != true || manager != activeManager {
            stop()
            guard let relay = Bundle.module.url(forResource: "github-package-access", withExtension: "py") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let child = Process()
            child.executableURL = URL(filePath: "/usr/bin/python3")
            child.arguments = ["-I", relay.path, config.path]
            if let manager {
                guard let app = Bundle.main.executableURL else { throw CocoaError(.executableNotLoadable) }
                child.arguments? += [manager.uuidString, app.path(percentEncoded: false)]
            }
            child.currentDirectoryURL = URL(filePath: "/")
            child.environment = ["PATH": "/usr/bin:/bin"]
            let commands = Pipe()
            guard fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let replies = Pipe()
            child.standardInput = commands
            child.standardOutput = replies
            let events = Pipe()
            child.standardError = events
            try child.run()
            commands.fileHandleForReading.closeFile()
            replies.fileHandleForWriting.closeFile()
            events.fileHandleForWriting.closeFile()
            process = child
            activeManager = manager
            input = commands.fileHandleForWriting
            acknowledgment = replies.fileHandleForReading
            requests = Task {
                let reader = events.fileHandleForReading
                defer { reader.closeFile() }
                do {
                    for try await event in reader.bytes.lines where manager == nil && event == "credential" {
                        let token = (try? await authentication.accessToken()) ?? ""
                        guard process === child, !Task.isCancelled else { return }
                        try commands.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(["credential": token]) + Data([10]))
                    }
                } catch {
                    if process === child { stop() }
                }
            }
        }
        let access = ["repositories": names]
        do {
            try input?.write(contentsOf: JSONEncoder().encode(access) + Data([10]))
            guard acknowledgment?.readData(ofLength: 6) == Data("ready\n".utf8), let process else {
                throw HostSettingsError("GitHub package access did not start.")
            }
            return Relay(process: process, repositories: allowed)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        requests?.cancel()
        requests = nil
        input?.closeFile()
        if process?.isRunning == true { process?.terminate() }
        acknowledgment?.closeFile()
        process = nil
        input = nil
        acknowledgment = nil
        // An include for a missing file is ignored by Git.
        try? FileManager.default.removeItem(at: config)
        try? FileManager.default.removeItem(at: config.deletingPathExtension().appendingPathExtension("json"))
    }
}

enum PackageRouting: Codable, Equatable, Sendable {
    case applied([String])
    case failed(String)
}

enum PackageAccessChange: Codable, Sendable {
    case list
    case add(String)
    case remove(String)
}

/// One HTTP exchange in Git's read-only smart HTTP protocol. Bodies travel in chunks on the pairing connection.
struct PackageFetch: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case refs, uploadPack }
    struct Response: Codable, Sendable {
        let status: Int
        let length: Int64?
        let contentType: String?
    }

    let repository: String
    let operation: Operation
    let protocolV2: Bool
    let gzip: Bool

    static let idleTimeout: TimeInterval = 120

    static func validRepository(_ name: String) -> Bool {
        guard name.wholeMatch(of: #/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/#) != nil else { return false }
        return !name.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    static func serviceName(_ pairing: UUID) -> String { "packages-" + pairing.uuidString }

    /// Git's loopback HTTP helper invokes the signed app so the pairing key stays in Keychain.
    func run(manager id: UUID, root: URL, input: FileHandle, output: FileHandle) async throws {
        let store = KeychainSecretStore.managingHost(hostRoot: root)
        guard let data = try store.read(),
              let manager = try JSONDecoder().decode(HostManagement.Record.self, from: data).manager,
              manager.id == id else { throw HostSettingsError("The package host no longer manages this Mac.") }
        let endpoint = NWEndpoint.service(name: Self.serviceName(id), type: HostLink.managementService, domain: "local.", interface: nil)
        try await transfer(to: endpoint, manager: manager, input: input, output: output)
    }

    func transfer(to endpoint: NWEndpoint, manager: HostPairing, input: FileHandle, output: FileHandle) async throws {
        try await HostLink.exchange(with: endpoint, key: manager.symmetricKey, identity: manager.id.uuidString) { connection in
            let exchange = HostLink.Exchange(
                send: { message in try await HostLink.within(.seconds(Self.idleTimeout)) { try await connection.send(message) } },
                receive: { try await HostLink.within(.seconds(Self.idleTimeout), connection.receive) }
            )
            try await HostLink.within(HostLink.requestTimeout) {
                try await exchange.send(.fetchPackage(self))
                let reply = try await exchange.receive()
                if case .refused(let reason) = reply { throw HostSettingsError(reason) }
                guard case .completed = reply else { throw HostLinkError.unexpectedReply }
            }
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try await exchange.send(.packageData(chunk))
            }
            try await exchange.send(.packageEnd)
            let first = try await exchange.receive()
            if case .refused(let reason) = first { throw HostSettingsError(reason) }
            guard case .packageResponse(let headers) = first else { throw HostLinkError.unexpectedReply }
            try output.write(contentsOf: JSONEncoder().encode(headers) + Data([10]))
            while true {
                switch try await exchange.receive() {
                case .packageData(let chunk): try output.write(contentsOf: chunk)
                case .packageEnd: return
                case .refused(let reason): throw HostSettingsError(reason)
                default: throw HostLinkError.unexpectedReply
                }
            }
        }
    }
}

extension PackageFetch {
    /// Git's http-backend defaults to 10 MiB for ref negotiation. Pack data flows in the response.
    static let maximumRequestSize = 10 * 1024 * 1024

    @concurrent func receiveBody(next: @escaping @Sendable () async throws -> HostLinkRequest) async throws -> Data? {
        try await HostLink.within(.seconds(120)) {
            var body = Data()
            while true {
                switch try await next() {
                case .packageEnd: return operation == .refs ? nil : body
                case .packageData(let data) where operation == .uploadPack:
                    guard data.count <= Self.maximumRequestSize - body.count else {
                        throw HostSettingsError("Git's ref negotiation request exceeds 10 MiB.")
                    }
                    body.append(data)
                default: throw HostLinkError.unexpectedReply
                }
            }
        }
    }

    @concurrent func sendResponse(
        to request: URLRequest, reply: @escaping @Sendable (HostLinkReply) async throws -> Void
    ) async throws {
        let (events, continuation) = AsyncThrowingStream<HostLinkReply, any Error>.makeStream()
        let session = URLSession(configuration: .ephemeral, delegate: PackageResponseDelegate(continuation), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        for try await event in events {
            if case .packageData(let data) = event {
                var start = data.startIndex
                while start < data.endIndex {
                    let end = start + min(64 * 1024, data.endIndex - start)
                    try await reply(.packageData(data[start..<end]))
                    start = end
                }
                task.resume()
            } else {
                try await reply(event)
            }
        }
        try Task.checkCancellation()
        try await reply(.packageEnd)
    }
}

/// Forwards each delivery as it arrives, including Git progress while the server prepares a pack.
private final class PackageResponseDelegate: NSObject, URLSessionDataDelegate {
    private let events: AsyncThrowingStream<HostLinkReply, any Error>.Continuation

    init(_ events: AsyncThrowingStream<HostLinkReply, any Error>.Continuation) { self.events = events }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            events.finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        let length = http.expectedContentLength
        events.yield(.packageResponse(.init(status: http.statusCode, length: length < 0 ? nil : length,
                                            contentType: http.value(forHTTPHeaderField: "Content-Type"))))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The consumer resumes the task when the runner has taken this data. A slow runner cannot buffer a whole pack.
        dataTask.suspend()
        events.yield(.packageData(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        events.finish(throwing: error)
    }
}
