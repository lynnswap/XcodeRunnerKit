import CryptoKit
import Foundation
import Network
import Subprocess
import XcodeRunnerHostSupport

/// A Git checkout on this Mac whose files a host builds.
struct Checkout: Equatable, Sendable {
    /// The checkout's top folder.
    let root: URL
    /// The directory inside the checkout that the command ran in, or an empty string for `root`.
    let directory: String
    /// Identifies the checkout's repository. Every worktree of a repository has the same value, so a host unpacks
    /// them at one path and their builds share compiler cache entries.
    let repository: String
    /// The repository's folder name.
    let name: String

    /// Finds the checkout that contains `directory`.
    static func containing(_ directory: URL) async throws -> Checkout {
        let lines = try await git(
            ["rev-parse", "--show-toplevel", "--show-prefix", "--path-format=absolute", "--git-common-dir"], in: directory
        ).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[0].hasPrefix("/"), lines[2].hasPrefix("/") else {
            throw RemoteOperationFailure("Git did not name the checkout that contains \(directory.path(percentEncoded: false)).")
        }
        let root = URL(filePath: lines[0])
        let common = URL(filePath: lines[2])
        // A worktree's folder is named after its branch or task. The folder that holds the repository is not.
        let name = common.lastPathComponent == ".git" ? common.deletingLastPathComponent().lastPathComponent : root.lastPathComponent
        var prefix = lines[1]
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return Checkout(
            root: root, directory: prefix,
            repository: SHA256.hash(data: Data(common.path(percentEncoded: false).utf8)).map { String(format: "%02x", $0) }.joined(),
            name: name
        )
    }

    /// The files that Git tracks or would add, as they are in the working tree, with those of submodules and of
    /// other repositories inside the checkout. Paths are relative to `root`.
    func files() async throws -> [String] {
        try await Self.files(in: root, under: "")
    }

    private static func files(in repository: URL, under prefix: String) async throws -> [String] {
        let listed = try await git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: repository)
        var files: [String] = []
        var seen: Set<String> = []
        for entry in listed.split(separator: "\0") {
            // Git lists a repository that it does not track with a trailing slash.
            var path = String(entry)
            while path.hasSuffix("/") { path.removeLast() }
            // An unmerged file is listed once for each version.
            guard seen.insert(path).inserted else { continue }
            let url = repository.appending(path: path)
            // A link is sent as a link, and a file deleted from the working tree is not sent.
            guard let type = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.type]
                    as? FileAttributeType else { continue }
            if type == .typeDirectory {
                // A submodule that is not checked out is an empty folder.
                guard FileManager.default.fileExists(atPath: url.appending(path: ".git").path(percentEncoded: false)) else { continue }
                files += try await Self.files(in: url, under: prefix + path + "/")
            } else {
                files.append(prefix + path)
            }
        }
        return files
    }

    private static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await Subprocess.run(
            .name("git"), arguments: .init(["-C", directory.path(percentEncoded: false)] + arguments),
            output: .string(limit: 1 << 28), error: .string(limit: 4096)
        )
        guard result.terminationStatus.isSuccess else {
            let reason = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteOperationFailure(reason.isEmpty ? "Git could not read \(directory.path(percentEncoded: false))." : reason)
        }
        return result.standardOutput
    }
}

/// Shows a host's folders in an operation's output as the matching folders on this Mac, so that the paths in
/// compiler messages and the paths of the log and result bundle open here.
struct PathRewriter {
    private let replacements: [(host: Data, local: Data)]
    /// The end of the output so far, when it is not a whole line. A path can arrive in two pieces.
    private var pending = Data()

    init(_ replacements: [(host: String, local: String)]) {
        // A folder is named with and without a slash at its end, and both name the matching folder.
        func folder(_ path: String) -> String {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        self.replacements = replacements.flatMap { replacement in
            let host = folder(replacement.host)
            let local = folder(replacement.local)
            // Xcode and xcode-runner name folders under /private/tmp and /private/var without /private.
            let spellings = host.hasPrefix("/private/") ? [host, String(host.dropFirst("/private".count))] : [host]
            // Xcode shows the commands that it runs with their spaces escaped.
            let escaped = spellings.filter { $0.contains(" ") }.map {
                ($0.replacing(" ", with: "\\ "), local.replacing(" ", with: "\\ "))
            }
            return (spellings.map { ($0, local) } + escaped).map { (Data($0.0.utf8), Data($0.1.utf8)) }
        }
    }

    /// The whole lines of the output so far that were not returned yet.
    mutating func rewrite(_ output: Data) -> Data {
        pending.append(output)
        guard let end = pending.lastIndex(of: UInt8(ascii: "\n")) else { return Data() }
        let lines = Data(pending[...end])
        pending = Data(pending[pending.index(after: end)...])
        return replace(in: lines)
    }

    /// The output after the last whole line.
    mutating func finish() -> Data {
        defer { pending = Data() }
        return replace(in: pending)
    }

    private func replace(in output: Data) -> Data {
        replacements.reduce(output) { output, replacement in
            var result = Data()
            var start = output.startIndex
            while let range = output.range(of: replacement.host, in: start..<output.endIndex) {
                result.append(output[start..<range.lowerBound])
                result.append(replacement.local)
                start = range.upperBound
            }
            result.append(output[start...])
            return result
        }
    }
}

/// Runs a build or test of a checkout on a host that this Mac shows.
enum RemoteOperationClient {
    /// Finds the service that a host advertises for its pairing with this Mac.
    ///
    /// Throws `HostLinkError.incompatible` when the host runs a version of the app whose messages this Mac does not
    /// read.
    static func find(_ host: PairedMac) async throws -> NWEndpoint {
        let identifier = host.id.uuidString
        let browser = NetworkBrowser(for: .bonjour(HostLink.managementService, includeTxtRecord: true))
        let found: (endpoint: NWEndpoint, version: Int)
        do {
            found = try await HostLink.within(HostLink.requestTimeout) {
                try await browser.run { services in
                    guard let service = services.first(where: { $0.txtRecord[HostLink.pairingKeyName] == identifier }) else {
                        return .continue
                    }
                    // A Mac that advertises no version runs one from before messages carried a version.
                    return .finish((service.nwEndpoint, service.txtRecord[HostLink.versionKeyName].flatMap { Int($0) } ?? 0))
                }
            }
        } catch HostLinkError.timedOut {
            throw HostLinkError.unreachable("\(host.name) was not found on the local network.")
        }
        guard found.version >= HostLink.oldestVersion else { throw HostLinkError.incompatible(.older) }
        return found.endpoint
    }

    /// Sends the checkout's files to the host and runs the command there. The log and result bundle are copied
    /// into a folder that the host names, inside `outputDirectory`, and the log names this Mac's folders as the
    /// output does.
    ///
    /// Cancelling the task ends the connection, and the host then stops the command.
    ///
    /// - Parameters:
    ///   - action: The `xcode-runner` command: `build`, `build-for-testing`, or `test`.
    ///   - arguments: The command's options, without those that name the host's own folders.
    ///   - version: The version of this Mac's messages.
    ///   - output: Takes the command's output as it arrives, with the host's folders shown as this Mac's.
    /// - Returns: The command's exit status.
    static func run(
        _ action: String, arguments: [String], in checkout: Checkout, on host: PairedMac, at endpoint: NWEndpoint,
        outputDirectory: URL, version: Int = HostLink.version, output: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int32 {
        let files = try await checkout.files()
        return try await HostLink.exchange(
            with: endpoint, key: host.pairing.symmetricKey, identity: host.id.uuidString, version: version
        ) { exchange in
            let operation = RemoteOperation(
                repository: checkout.repository, name: checkout.name, directory: checkout.directory, action: action,
                arguments: arguments
            )
            let accepted = try await HostLink.within(HostLink.requestTimeout) {
                try await exchange.send(.operation(.start(operation)))
                return try await exchange.receive()
            }
            guard case .operation(.accepted(let hostCheckout, let hostOutput)) = accepted else { throw unexpected(accepted) }
            try await send(files, of: checkout, through: exchange)
            var rewriter = PathRewriter([
                (hostCheckout, checkout.root.path(percentEncoded: false)), (hostOutput, outputDirectory.path(percentEncoded: false)),
            ])
            var status: Int32?
            // The results are unpacked beside their place, and appear there once they are whole.
            var results: (folder: URL, handle: FileHandle?)?
            do {
                events: while true {
                    switch try await exchange.receive() {
                    case .operation(.output(let data)):
                        try output(rewriter.rewrite(data))
                    case .operation(.exited(let code)):
                        try output(rewriter.finish())
                        status = code
                    case .operation(.results(let data)):
                        if results == nil {
                            let folder = outputDirectory.appending(path: ".results-\(UUID().uuidString)")
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let archive = folder.appending(path: resultsArchiveName)
                            results = (folder, nil)
                            guard FileManager.default.createFile(atPath: archive.path(percentEncoded: false), contents: nil) else {
                                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: archive])
                            }
                            results?.handle = try FileHandle(forWritingTo: archive)
                        }
                        try results?.handle?.write(contentsOf: data)
                    case .operation(.finished):
                        guard status != nil else { throw HostLinkError.unexpectedReply }
                        try results?.handle?.close()
                        break events
                    case let reply:
                        throw unexpected(reply)
                    }
                }
            } catch {
                // An archive that did not arrive whole has nothing to unpack.
                if let results { try? FileManager.default.removeItem(at: results.folder) }
                throw error
            }
            guard let status else { throw HostLinkError.unexpectedReply }
            if let results { try await unpackResults(in: results.folder, into: outputDirectory, rewriter: rewriter) }
            // The host has nothing more to send, and removed what the operation left.
            try? await exchange.send(.operation(.received))
            return status
        }
    }

    /// Runs an `xcode-runner` command on a host for the command line: the checkout is the one that contains the
    /// current directory, and the output goes to standard output.
    ///
    /// - Parameter command: The command and its options.
    /// - Returns: The process's exit status, which is the command's unless this Mac or the host could not run it.
    @MainActor static func run(
        _ command: [String], onHostNamed hostName: String, installation: HostInstallation, outputDirectory: URL
    ) async -> Int32 {
        do {
            let hosts = PairedMacs(
                store: KeychainSecretStore.dashboardHosts(hostRoot: installation.hostRoot), name: HostPane.macName,
                role: .dashboard, browses: false
            )
            if let message = hosts.message { throw RemoteOperationFailure(message) }
            let named = hosts.macs.filter { $0.name.localizedCaseInsensitiveCompare(hostName) == .orderedSame }
            guard let host = named.first else {
                let shown = hosts.macs.map(\.name).sorted().joined(separator: ", ")
                throw RemoteOperationFailure("XcodeHomeRunner on this Mac shows no host named \(hostName). "
                    + (shown.isEmpty ? "Open XcodeHomeRunner and add the host first." : "It shows \(shown)."))
            }
            guard named.count == 1 else {
                throw RemoteOperationFailure("XcodeHomeRunner on this Mac shows \(named.count) hosts named \(hostName). Remove the ones that you no longer use.")
            }
            let checkout = try await Checkout.containing(.currentDirectory())
            let endpoint = try await find(host)
            return try await run(
                command[0], arguments: Array(command.dropFirst()), in: checkout, on: host, at: endpoint,
                outputDirectory: outputDirectory
            ) { try FileHandle.standardOutput.write(contentsOf: $0) }
        } catch {
            // The shell's status for a command that an interrupt ended.
            if Task.isCancelled { return 130 }
            try? FileHandle.standardError.write(contentsOf: Data("Error: \(error.localizedDescription)\n".utf8))
            return EXIT_FAILURE
        }
    }

    /// Sends the files as a tar archive, which keeps links and executable files as they are.
    private static func send(_ files: [String], of checkout: Checkout, through exchange: HostLink.Exchange) async throws {
        let list = FileManager.default.temporaryDirectory.appending(path: "xcode-runner-files-\(UUID().uuidString)")
        try Data(files.joined(separator: "\0").utf8).write(to: list)
        defer { try? FileManager.default.removeItem(at: list) }
        let archive = try await Subprocess.run(
            .path("/usr/bin/tar"),
            // Extended attributes, such as the quarantine of a downloaded file, stay on this Mac.
            arguments: [
                "-cf", "-", "--no-mac-metadata", "--no-xattrs", "-n", "-C", checkout.root.path(percentEncoded: false),
                "--null", "-T", list.path(percentEncoded: false),
            ],
            input: .none, output: .sequence, error: .discarded
        ) { execution in
            for try await buffer in execution.standardOutput {
                try await exchange.send(.operation(.files(buffer.withUnsafeBytes { Data($0) })))
            }
        }
        guard archive.terminationStatus.isSuccess else {
            throw RemoteOperationFailure("Could not archive the files of \(checkout.root.path(percentEncoded: false)).")
        }
        try await exchange.send(.operation(.filesEnd))
    }

    private static let resultsArchiveName = "results.tar"

    /// Unpacks the archive in `folder`, shows the host's folders in each log as this Mac's, and moves the
    /// operation's folder into `directory`.
    private static func unpackResults(in folder: URL, into directory: URL, rewriter: PathRewriter) async throws {
        let archive = folder.appending(path: resultsArchiveName)
        let unpacking = try await Subprocess.run(
            .path("/usr/bin/tar"),
            arguments: ["-xf", archive.path(percentEncoded: false), "-C", folder.path(percentEncoded: false)],
            output: .discarded, error: .string(limit: 4096)
        )
        guard unpacking.terminationStatus.isSuccess else {
            throw RemoteOperationFailure(
                "Could not unpack the log and result bundle. They are in \(archive.path(percentEncoded: false)): \(unpacking.standardError)"
            )
        }
        try FileManager.default.removeItem(at: archive)
        for job in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let log = job.appending(path: "xcodebuild.log")
            if FileManager.default.fileExists(atPath: log.path(percentEncoded: false)) {
                var rewriter = rewriter
                let rewritten = job.appending(path: "xcodebuild.log.rewritten")
                guard FileManager.default.createFile(atPath: rewritten.path(percentEncoded: false), contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: rewritten])
                }
                let reading = try FileHandle(forReadingFrom: log)
                let writing = try FileHandle(forWritingTo: rewritten)
                while let piece = try reading.read(upToCount: 1 << 20), !piece.isEmpty {
                    try writing.write(contentsOf: rewriter.rewrite(piece))
                }
                try writing.write(contentsOf: rewriter.finish())
                try reading.close()
                try writing.close()
                _ = try FileManager.default.replaceItemAt(log, withItemAt: rewritten)
            }
            try FileManager.default.moveItem(at: job, to: directory.appending(path: job.lastPathComponent))
        }
        try FileManager.default.removeItem(at: folder)
    }

    private static func unexpected(_ reply: HostLinkReply) -> HostLinkError {
        if case .refused(let message) = reply { return .refused(message) }
        return .unexpectedReply
    }
}
