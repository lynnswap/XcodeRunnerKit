import CryptoKit
import Foundation
import Subprocess
import XcodeRunnerHostSupport

/// Why this Mac could not run a dashboard's build or test, as the dashboard shows it.
struct RemoteOperationFailure: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

/// Runs the builds and tests that dashboards send, as this Mac's runners run their jobs: with its storage, its saved
/// Xcode, and its job limit.
@MainActor
final class RemoteOperations {
    private let installation: HostInstallation
    /// The command-line tool that jobs on this Mac use.
    private let tool: URL
    /// The storage that jobs use, once the host prepared it.
    var storage: HostInstallation.Storage?
    /// The folders of the checkouts that operations use now.
    private var foldersInUse: Set<URL> = []

    init(installation: HostInstallation, tool: URL) {
        self.installation = installation
        self.tool = tool
    }

    /// The dashboard's connection ended while it sent the checkout.
    private struct DashboardLeft: Error {
        let reason: any Error
    }

    private enum Step: Sendable {
        /// The dashboard has every event, or it left.
        case acknowledged(Result<Void, any Error>)
        case ran(Result<Void, any Error>)
    }

    /// Receives a checkout, runs the operation in it, and sends its output, exit status, log, and result bundle. A
    /// failure on this Mac is sent as a refusal.
    ///
    /// Throws when the connection ends before the operation does, which stops the operation.
    ///
    /// - Parameters:
    ///   - next: Waits for the dashboard's next message.
    ///   - reply: Sends an event or a refusal to the dashboard.
    func run(
        _ operation: RemoteOperation, for dashboard: HostPairing.ID,
        next: @escaping @Sendable () async throws -> HostLinkRequest,
        reply: @escaping @Sendable (HostLinkReply) async throws -> Void
    ) async throws {
        guard let storage else {
            try await reply(.refused("\(HostPane.macName) has not prepared its storage."))
            return
        }
        // Dashboards choose what they call a repository, so each dashboard's repositories get folders of their own.
        let key = SHA256.hash(data: Data("\(dashboard.uuidString)/\(operation.repository)".utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let repository = storage.workDirectory.appending(path: "Remote/\(key)")
        // A repository's folder stays only while a checkout uses it.
        defer { rmdir(repository.path(percentEncoded: false)) }
        // Operations on one repository that overlap each need a folder. The first of them gets the folder that
        // earlier operations used, and with it their compiler cache entries.
        var index = 0
        var folder = repository.appending(path: "0")
        while foldersInUse.contains(folder) {
            index += 1
            folder = repository.appending(path: String(index))
        }
        foldersInUse.insert(folder)
        // Another operation can take the folder once this one frees it, so this one frees it once.
        var holdsFolder = true
        defer {
            if holdsFolder { foldersInUse.remove(folder) }
        }
        let checkout = folder.appending(path: operation.name)
        let output = storage.buildDirectory.appending(path: "Remote/\(UUID().uuidString)")
        let tool = tool
        let environment = installation.environment(for: storage)
        // Operations from every dashboard share one cache, apart from the repositories that run jobs from GitHub.
        let cache = storage.compilationCacheDirectory.appending(path: "remote")
        try await reply(.operation(.accepted(
            checkoutDirectory: checkout.path(percentEncoded: false), outputDirectory: output.path(percentEncoded: false)
        )))
        do {
            // Creating the folders of storage that is not mounted would run the operation on the startup volume.
            for location in [storage.workDirectory, storage.buildDirectory] {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: location.path(percentEncoded: false), isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw RemoteOperationFailure(
                        "\(HostPane.macName)'s storage is not available at \(storage.directory.path(percentEncoded: false))."
                    )
                }
            }
            // An operation that the host did not finish, as when it quit, left its checkout.
            try await Self.remove(folder)
            try await Self.receiveCheckout(into: checkout, archive: folder.appending(path: "files.tar"), next: next)
        } catch let left as DashboardLeft {
            for message in await Self.removeAll([folder]) { print(message) }
            throw left.reason
        } catch {
            let leftovers = await Self.removeAll([folder])
            try await reply(.refused(([error.localizedDescription] + leftovers).joined(separator: " ")))
            return
        }
        try await withThrowingTaskGroup(of: Step.self) { group in
            // The dashboard sends nothing more until it has every event, so this ends first only when it leaves.
            group.addTask {
                do {
                    guard case .operation(.received) = try await next() else { throw HostLinkError.unexpectedReply }
                    return .acknowledged(.success(()))
                } catch {
                    return .acknowledged(.failure(error))
                }
            }
            group.addTask {
                do {
                    try await Self.execute(
                        operation, in: checkout, output: output, tool: tool, cache: cache, environment: environment, reply: reply
                    )
                    return .ran(.success(()))
                } catch {
                    return .ran(.failure(error))
                }
            }
            switch try await group.next() {
            case .acknowledged(let result):
                group.cancelAll()
                // The command ends before its files are removed.
                _ = try await group.next()
                for message in await Self.removeAll([folder, output]) { print(message) }
                try result.get()
                throw HostLinkError.unexpectedReply
            case .ran(let result):
                var failures = await Self.removeAll([folder, output])
                if case .failure(let error) = result { failures.insert(error.localizedDescription, at: 0) }
                // The dashboard's next operation can arrive before it acknowledges this one.
                if failures.isEmpty {
                    foldersInUse.remove(folder)
                    holdsFolder = false
                }
                // The dashboard has the exit status, so it learns what this Mac kept as well.
                try await reply(failures.isEmpty ? .operation(.finished) : .refused(failures.joined(separator: " ")))
                _ = try await group.next()
            case nil:
                break
            }
        }
    }

    /// Saves the archive that the dashboard sends until `filesEnd`, and unpacks it.
    ///
    /// Throws `DashboardLeft` when the connection ends first, and otherwise why this Mac could not keep the files.
    @concurrent private nonisolated static func receiveCheckout(
        into checkout: URL, archive: URL, next: @Sendable () async throws -> HostLinkRequest
    ) async throws {
        var saving: Result<FileHandle, any Error>
        do {
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: archive.path(percentEncoded: false), contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: archive])
            }
            saving = .success(try FileHandle(forWritingTo: archive))
        } catch {
            saving = .failure(error)
        }
        receiving: while true {
            let message: HostLinkRequest
            do { message = try await next() } catch { throw DashboardLeft(reason: error) }
            switch message {
            case .operation(.files(let data)):
                // The dashboard sends the whole archive before it reads a reply, so the rest is received after a
                // failure too.
                if case .success(let handle) = saving {
                    do { try handle.write(contentsOf: data) } catch { saving = .failure(error) }
                }
            case .operation(.filesEnd): break receiving
            default: throw DashboardLeft(reason: HostLinkError.unexpectedReply)
            }
        }
        do {
            try saving.get().close()
        } catch {
            throw RemoteOperationFailure("\(HostPane.macName) could not save the checkout: \(error.localizedDescription)")
        }
        let unpacking = try await Subprocess.run(
            .path("/usr/bin/tar"),
            arguments: ["-xf", archive.path(percentEncoded: false), "-C", checkout.path(percentEncoded: false)],
            output: .discarded, error: .string(limit: 4096)
        )
        guard unpacking.terminationStatus.isSuccess else {
            throw RemoteOperationFailure("\(HostPane.macName) could not unpack the checkout: \(unpacking.standardError)")
        }
        do {
            try FileManager.default.removeItem(at: archive)
        } catch {
            throw RemoteOperationFailure("\(HostPane.macName) could not unpack the checkout: \(error.localizedDescription)")
        }
    }

    /// Runs the command in the checkout and sends its output, its exit status, and its log and result bundles.
    @concurrent private nonisolated static func execute(
        _ operation: RemoteOperation, in checkout: URL, output: URL, tool: URL, cache: URL, environment: [String: String],
        reply: @Sendable (HostLinkReply) async throws -> Void
    ) async throws {
        var options = PlatformOptions()
        // Asked to end, the tool stops its build, returns its Simulator, and frees its place in the job limit.
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(30))]
        // The host's folders come first, so that they are options even when the operation passes arguments to
        // xcodebuild after "--".
        let arguments = [
            operation.action, "--output-directory=\(output.path(percentEncoded: false))",
            "--compilation-cache=\(cache.path(percentEncoded: false))",
        ] + operation.arguments
        let directory = operation.directory.isEmpty ? checkout : checkout.appending(path: operation.directory)
        // The archive has no folders without files, and the dashboard's current directory can be one.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let command: ExecutionResult<Void, SequenceOutput, CombinedErrorOutput>
        do {
            command = try await Subprocess.run(
                .path(.init(tool.path(percentEncoded: false))), arguments: .init(arguments),
                environment: .inherit.updating(Dictionary(uniqueKeysWithValues: environment.map {
                    (Environment.Key(stringLiteral: $0.key), Optional($0.value))
                })),
                workingDirectory: .init(directory.path(percentEncoded: false)),
                platformOptions: options, input: .none, output: .sequence, error: .combinedWithOutput
            ) { execution in
                for try await buffer in execution.standardOutput {
                    try await reply(.operation(.output(buffer.withUnsafeBytes { Data($0) })))
                }
            }
        } catch let error as SubprocessError {
            // The error names the tool or the directory that is missing.
            throw RemoteOperationFailure("\(HostPane.macName) could not start the operation: \(error)")
        }
        let status: Int32 = switch command.terminationStatus {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
        try await reply(.operation(.exited(status)))
        // The tool keeps each operation's log and result bundles in a folder that it names, beside its build products.
        let results = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).flatMap { job in
            try FileManager.default.contentsOfDirectory(atPath: job.path(percentEncoded: false))
                .filter { $0 == "xcodebuild.log" || $0.hasSuffix(".xcresult") }.map { job.lastPathComponent + "/" + $0 }
        }
        guard !results.isEmpty else { return }
        let archive = try await Subprocess.run(
            .path("/usr/bin/tar"), arguments: .init(["-cf", "-", "-C", output.path(percentEncoded: false)] + results),
            input: .none, output: .sequence, error: .discarded
        ) { execution in
            for try await buffer in execution.standardOutput {
                try await reply(.operation(.results(buffer.withUnsafeBytes { Data($0) })))
            }
        }
        guard archive.terminationStatus.isSuccess else {
            throw RemoteOperationFailure("\(HostPane.macName) could not send the log and result bundle.")
        }
    }

    /// Removes a folder that may not exist.
    @concurrent private nonisolated static func remove(_ folder: URL) async throws {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            throw RemoteOperationFailure(
                "\(HostPane.macName) could not remove \(folder.path(percentEncoded: false)): \(error.localizedDescription)"
            )
        }
    }

    /// Removes what an operation leaves.
    ///
    /// - Returns: What could not be removed, and why.
    private nonisolated static func removeAll(_ folders: [URL]) async -> [String] {
        var failures: [String] = []
        for folder in folders {
            do { try await remove(folder) } catch { failures.append(error.localizedDescription) }
        }
        return failures
    }
}
