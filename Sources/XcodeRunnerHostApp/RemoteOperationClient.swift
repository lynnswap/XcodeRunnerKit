import CryptoKit
import Foundation
import Network
import Subprocess
import Synchronization
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
    func files(excludingResultsIn destination: URL? = nil) async throws -> [String] {
        var excluded = Set<String>()
        if let destination {
            let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let output = destination.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            if output.starts(with: base) {
                let relative = output.dropFirst(base.count)
                let prefix = relative.isEmpty ? "" : relative.joined(separator: "/") + "/"
                let items: [String]
                do { items = try FileManager.default.contentsOfDirectory(atPath: destination.path) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { items = [] }
                for name in items where UUID(uuidString: name) != nil {
                    let job = destination.appending(component: name)
                    if ["workflow.log", "xcodebuild.log"].contains(where: { FileManager.default.fileExists(atPath: job.appending(component: $0).path) }) {
                        excluded.insert(prefix + name)
                    }
                }
            }
        }
        return try await Self.files(in: root, under: "", excluding: excluded)
    }

    private static func files(in repository: URL, under prefix: String, excluding: Set<String>) async throws -> [String] {
        let listed = try await git(["ls-files", "-t", "-z", "--cached", "--others", "--exclude-standard"], in: repository)
        var files: [String] = []
        var seen: Set<String> = []
        for entry in listed.split(separator: "\0") {
            // Git lists a repository that it does not track with a trailing slash.
            var path = String(entry.dropFirst(2))
            while path.hasSuffix("/") { path.removeLast() }
            // An unmerged file is listed once for each version.
            guard seen.insert(path).inserted else { continue }
            let relative = prefix + path
            if entry.hasPrefix("? "), excluding.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { continue }
            let url = repository.appending(path: path)
            // A link is sent as a link, and a file deleted from the working tree is not sent.
            guard let type = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.type]
                    as? FileAttributeType else { continue }
            if type == .typeDirectory {
                // A submodule that is not checked out is an empty folder.
                guard FileManager.default.fileExists(atPath: url.appending(path: ".git").path(percentEncoded: false)) else { continue }
                files += try await Self.files(in: url, under: prefix + path + "/", excluding: excluding)
            } else {
                files.append(prefix + path)
            }
        }
        return files
    }

    /// Workflow conditions use the dashboard's repository and ref even though the host receives only files.
    func workflow(file: String, event: String, base: String = "") async throws -> WorkflowInvocation {
        let url = URL(filePath: file, relativeTo: root.appending(path: directory, directoryHint: .isDirectory))
            .standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.resolvingSymlinksInPath().path(percentEncoded: false) + "/"
        guard url.path(percentEncoded: false).hasPrefix(prefix), FileManager.default.fileExists(atPath: url.path) else {
            throw RemoteOperationFailure("Choose a workflow file in this checkout.")
        }
        let origin = try await Self.git(["remote", "get-url", "origin"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // HTTPS, ssh:// URLs and Git's scp-style user@host:owner/repo all name the same repository.
        let path: String
        if let url = URLComponents(string: origin), url.host != nil {
            path = url.path
        } else {
            path = origin.components(separatedBy: ":").last ?? origin
        }
        let parts = path.split(separator: "/").suffix(2)
        guard parts.count == 2 else { throw RemoteOperationFailure("The origin remote must name an owner and repository.") }
        var repository = parts.joined(separator: "/")
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        let sha = try await Self.git(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        var ref = try await Self.git(["rev-parse", "--symbolic-full-name", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ref == "HEAD" {
            let tags = try await Self.git(["tag", "--points-at", "HEAD"], in: root).split(separator: "\n")
            ref = tags.count == 1 ? "refs/tags/" + tags[0] : sha
        }
        var base = base
        if base.isEmpty, let remote = try? await Self.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root) {
            base = String(remote.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("origin/".count))
        }
        if base.isEmpty && event.hasPrefix("pull_request") {
            throw RemoteOperationFailure("Specify the pull request target with --base when origin has no default branch.")
        }
        let definition = try String(contentsOf: url, encoding: .utf8)
        let file = String(url.path(percentEncoded: false).dropFirst(prefix.count))
        let listed = try await Self.git(["--literal-pathspecs", "ls-files", "-z", "--cached", "--others",
                                         "--exclude-standard", "--", file, ".github/workflows"], in: root)
        let allowed = listed.split(separator: "\0").map(String.init)
        guard allowed.contains(file) else { throw RemoteOperationFailure("The selected workflow is excluded from the checkout.") }
        // Reusable workflow references are literal job.uses strings. Ship only their transitive definitions.
        let references = try await Subprocess.run(.path("/usr/bin/ruby"), arguments: .init(["-ryaml", "-rjson", "-e", #"""
            root, entry = ARGV
            allowed = JSON.parse(STDIN.read)
            # Actions treats plain job IDs and paths as strings, including Ruby/YAML 1.1 scalars.
            loader = Psych::ClassLoader::Restricted.new([], [])
            class WorkflowStrings < Psych::Visitors::ToRuby
              def visit_Psych_Nodes_Scalar(node)
                register(node, node.value)
              end
            end
            queue, seen, definitions = [entry], {}, {}
            until queue.empty?
              file = queue.pop
              next if seen[file]
              seen[file] = true
              text = File.read(File.join(root, file))
              definitions[File.basename(file)] = text unless file == entry
              workflow = WorkflowStrings.new(Psych::ScalarScanner.new(loader), loader).accept(Psych.parse(text))
              (workflow.fetch("jobs", {}) || {}).each_value do |job|
                path = job["uses"].to_s.delete_prefix("./")
                next unless job["uses"].to_s.start_with?("./.github/workflows/")
                raise "Unavailable local workflow: #{path}" unless allowed.include?(path) &&
                  File.realpath(File.join(root, path)).start_with?(File.realpath(root) + "/")
                queue << path
              end
            end
            print JSON.generate(definitions)
            """#, root.path, file]),
            input: .string(String(decoding: try JSONEncoder().encode(allowed), as: UTF8.self)),
            output: .string(limit: 1 << 24), error: .string(limit: 4096))
        guard references.terminationStatus.isSuccess else { throw RemoteOperationFailure(references.standardError) }
        let localWorkflows = try JSONDecoder().decode([String: String].self, from: Data(references.standardOutput.utf8))
        return WorkflowInvocation(
            file: file, event: event, repository: repository,
            sha: sha, ref: ref, base: base, definition: definition, localWorkflows: localWorkflows
        )
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

    /// Only failures before acceptance can be tried on another Mac. The transport may report
    /// a disconnection independently of the task that streams the checkout and results.
    static func exchange<T: Sendable>(
        _ request: RemoteOperationRequest, with host: PairedMac, at endpoint: NWEndpoint, version: Int = HostLink.version,
        body: @escaping @Sendable (HostLinkReply, HostLink.Exchange) async throws -> T
    ) async throws -> T {
        let accepted = Mutex(false)
        do {
            return try await HostLink.exchange(with: endpoint, key: host.pairing.symmetricKey, identity: host.id.uuidString, version: version) { link in
                var response = try await HostLink.within(HostLink.requestTimeout) {
                    try await link.send(.operation(request))
                    return try await link.receive()
                }
                // The host has answered and may now contact several workers, each with its own deadline.
                if request.dispatches, case .operation(.dispatching) = response { response = try await link.receive() }
                switch response {
                case .operation(.needsRuntimeDownload): throw HostAvailability.needsRuntimeDownload
                case .operation(.busy): throw HostAvailability.busy
                case .operation(.unavailable(let reason)): throw HostAvailability.unavailable(reason)
                case .operation(.accepted): break
                default: throw unexpected(response)
                }
                accepted.withLock { $0 = true }
                return try await body(response, link)
            }
        } catch {
            try Task.checkCancellation()
            if case .start = request { throw error }
            if accepted.withLock({ $0 }) || error is HostAvailability { throw error }
            throw HostAvailability.unavailable(error.localizedDescription)
        }
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
        _ action: String, arguments: [String], workflow: WorkflowInvocation? = nil, in checkout: Checkout, on host: PairedMac, at endpoint: NWEndpoint,
        outputDirectory: URL, automatic: Bool = false, allowRuntimeDownload: Bool = false, version: Int = HostLink.version, output: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int32 {
        let operation = RemoteOperation(
            repository: checkout.repository, name: checkout.name, directory: checkout.directory, action: action, arguments: arguments, workflow: workflow
        )
        let request: RemoteOperationRequest
        if action == "workflow" { request = .workflow(operation, dispatch: true) }
        else if automatic { request = .dispatch(operation, allowRuntimeDownload: allowRuntimeDownload) }
        else { request = .start(operation) }
        return try await exchange(request, with: host, at: endpoint, version: version) { accepted, exchange in
            guard case .operation(.accepted(let hostCheckout, let hostOutput)) = accepted else { throw unexpected(accepted) }
            try await send(checkout.files(excludingResultsIn: outputDirectory), of: checkout, workflow: workflow, through: exchange)
            var rewriter = PathRewriter([
                (hostCheckout, checkout.root.path(percentEncoded: false)), (hostOutput, outputDirectory.path(percentEncoded: false)),
            ])
            var status: Int32?
            var diagnostic = Data()
            // The results are unpacked beside their place, and appear there once they are whole.
            var results: (folder: URL, handle: FileHandle?)?
            do {
                events: while true {
                    switch try await exchange.receive() {
                    case .operation(.output(let data)):
                        let bytes = rewriter.rewrite(data)
                        if workflow?.output == .json {
                            diagnostic = (diagnostic + bytes).suffix(2048)
                        } else { try output(bytes) }
                    case .operation(.exited(let code)):
                        let remaining = rewriter.finish()
                        if workflow?.output == .json { diagnostic = (diagnostic + remaining).suffix(2048) }
                        else { try output(remaining) }
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
            var folders: [URL] = []
            if let results {
                folders = try await unpackResults(in: results.folder, into: outputDirectory, rewriter: rewriter, workflow: workflow != nil)
            }
            // The host has nothing more to send, and removed what the operation left.
            try? await exchange.send(.operation(.received))
            if let workflow {
                guard let folder = folders.first, folders.count == 1 else {
                    throw RemoteOperationFailure("No workflow results were received. " + String(decoding: diagnostic, as: UTF8.self))
                }
                try output(WorkflowSummary.report(in: folder, format: workflow.output, exitCode: status))
            }
            return status
        }
    }

    @MainActor static func pairedHost(installation: HostInstallation) throws -> PairedMac? {
        let dashboard = PairedMacs(
            store: KeychainSecretStore.dashboardHost(hostRoot: installation.hostRoot), name: HostPane.macName,
            role: .dashboard, browses: false
        )
        if let message = dashboard.legacyHostMessage ?? dashboard.message { throw RemoteOperationFailure(message) }
        return dashboard.dashboardHost
    }

    /// Runs an `xcode-runner` command on a host for the command line: the checkout is the one that contains the
    /// current directory, and the output goes to standard output.
    ///
    /// - Parameter command: The command and its options.
    /// - Returns: The process's exit status, which is the command's unless this Mac or the host could not run it.
    @MainActor static func run(
        _ command: [String], installation: HostInstallation, outputDirectory: URL
    ) async -> Int32 {
        do {
            guard let host = try pairedHost(installation: installation) else {
                throw RemoteOperationFailure("Pair a host in XcodeHomeRunner to run this checkout, or pass --local.")
            }
            let checkout = try await Checkout.containing(.currentDirectory())
            return try await run(command, in: checkout, host: host, outputDirectory: outputDirectory,
                                 endpoint: find) { try FileHandle.standardOutput.write(contentsOf: $0) }
        } catch {
            // The shell's status for a command that an interrupt ended.
            if Task.isCancelled { return 130 }
            if command.first == "workflow", command.last == "json" {
                let message = String(error.localizedDescription.suffix(2048))
                if let data = try? JSONEncoder().encode(["status": "error", "message": message]) {
                    try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                }
            } else {
                try? FileHandle.standardError.write(contentsOf: Data("Error: \(error.localizedDescription)\n".utf8))
            }
            return EXIT_FAILURE
        }
    }

    static func run(
        _ command: [String], in checkout: Checkout, host: PairedMac, outputDirectory: URL,
        endpoint: @Sendable (PairedMac) async throws -> NWEndpoint,
        output: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int32 {
        var allowRuntimeDownload = false
        while true {
            try Task.checkCancellation()
            let address = try await endpoint(host)
            let workflow: WorkflowInvocation?
            if command.first == "workflow" {
                guard command.count == 5, let mode = WorkflowOutput(rawValue: command[4]) else { throw RemoteOperationFailure("Expected the workflow file, event and base branch.") }
                var invocation = try await checkout.workflow(file: command[1], event: command[2], base: command[3])
                invocation.output = mode
                workflow = invocation
            } else {
                workflow = nil
            }
            do {
                return try await run(command[0], arguments: workflow == nil ? Array(command.dropFirst()) : [], workflow: workflow,
                                     in: checkout, on: host, at: address, outputDirectory: outputDirectory, automatic: true,
                                     allowRuntimeDownload: allowRuntimeDownload, output: output)
            } catch HostAvailability.needsRuntimeDownload where !allowRuntimeDownload {
                allowRuntimeDownload = true
            } catch HostAvailability.busy {
                allowRuntimeDownload = false
                try await Task.sleep(for: .seconds(1))
            } catch HostAvailability.unavailable(let reason) {
                throw RemoteOperationFailure("\(host.name): \(reason)")
            }
        }
    }

    /// Sends the files as a tar archive, which keeps links and executable files as they are.
    private static func send(_ files: [String], of checkout: Checkout, workflow: WorkflowInvocation?, through exchange: HostLink.Exchange) async throws {
        let list = FileManager.default.temporaryDirectory.appending(path: "xcode-runner-files-\(UUID().uuidString)")
        try Data(files.joined(separator: "\0").utf8).write(to: list)
        defer { try? FileManager.default.removeItem(at: list) }
        var arguments = ["-cf", "-", "--no-mac-metadata", "--no-xattrs", "-n", "--null"]
        let temporary = URL.temporaryDirectory.appending(path: "xcode-workflow-git-" + UUID().uuidString)
        defer { if workflow != nil { try? FileManager.default.removeItem(at: temporary) } }
        if let workflow {
            guard let script = Bundle.module.url(forResource: "run-workflow", withExtension: "py") else {
                throw RemoteOperationFailure("The workflow helper is missing.")
            }
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            let snapshot = try await Subprocess.run(.path("/usr/bin/python3"), arguments: .init([
                script.path, "snapshot-git", checkout.root.path, temporary.path, workflow.sha, workflow.ref, workflow.repository
            ]), output: .discarded, error: .string(limit: 4096))
            guard snapshot.terminationStatus.isSuccess else { throw RemoteOperationFailure(snapshot.standardError) }
        }
        arguments += ["-C", checkout.root.path(percentEncoded: false), "-T", list.path(percentEncoded: false)]
        // bsdtar accepts a single -T list. Import the shallow repository's members from their own archive.
        if workflow != nil { arguments.append("@" + temporary.appending(path: "metadata.tar").path) }
        let archive = try await Subprocess.run(
            .path("/usr/bin/tar"), arguments: .init(arguments),
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
    private static func unpackResults(in folder: URL, into directory: URL, rewriter: PathRewriter, workflow: Bool) async throws -> [URL] {
        let archive = folder.appending(path: resultsArchiveName)
        // Only this directory receives archive entries. The archive and the rewritten log belong to the receiver.
        let payload = folder.appending(path: "payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        let jobs: [URL]
        var logs: [URL] = []
        do {
            try await extractResults(from: archive, into: payload)
            jobs = try FileManager.default.contentsOfDirectory(atPath: payload.path(percentEncoded: false)).map {
                payload.appending(component: $0, directoryHint: .notDirectory)
            }
            for job in jobs {
                try RemoteOperation.requireResultType(.typeDirectory, at: job)
                for name in try FileManager.default.contentsOfDirectory(atPath: job.path(percentEncoded: false)) {
                    let item = job.appending(component: name, directoryHint: .notDirectory)
                    if name.hasSuffix(".xcresult") || (workflow && name == "artifacts") {
                        try RemoteOperation.requireResultType(.typeDirectory, at: item)
                        try validateResultDirectory(at: item)
                    } else if workflow && name == "summary.json" {
                        try RemoteOperation.requireResultType(.typeRegular, at: item)
                    } else if name == "xcodebuild.log" || (workflow && name == "workflow.log") {
                        try RemoteOperation.requireResultType(.typeRegular, at: item)
                        logs.append(item)
                    } else {
                        throw RemoteOperationFailure("Unexpected file in the build results: \(name).")
                    }
                }
            }
        } catch {
            let reason = "\(error.localizedDescription) The received archive is at \(archive.path(percentEncoded: false))."
            do { try FileManager.default.removeItem(at: payload) }
            catch let cleanup {
                throw RemoteOperationFailure("\(reason) Could not remove \(payload.path): \(cleanup.localizedDescription)")
            }
            throw RemoteOperationFailure(reason)
        }
        try FileManager.default.removeItem(at: archive)
        for log in logs {
            try rewrite(log, with: rewriter, temporaryFile: folder.appending(path: "rewritten.log"))
        }
        for job in jobs {
            try FileManager.default.moveItem(at: job, to: directory.appending(component: job.lastPathComponent))
        }
        try FileManager.default.removeItem(at: folder)
        return jobs.map { directory.appending(component: $0.lastPathComponent) }
    }

    private static func extractResults(from archive: URL, into payload: URL) async throws {
        let unpacking = try await Subprocess.run(
            .path("/usr/bin/tar"),
            arguments: ["-xf", archive.path(percentEncoded: false), "--no-mac-metadata", "--no-xattrs", "-C", payload.path(percentEncoded: false)],
            output: .discarded, error: .string(limit: 4096)
        )
        guard unpacking.terminationStatus.isSuccess else {
            throw RemoteOperationFailure(
                "Could not unpack the log and result bundle: \(unpacking.standardError)"
            )
        }
    }

    private static func rewrite(_ log: URL, with rewriter: PathRewriter, temporaryFile rewritten: URL) throws {
        var rewriter = rewriter
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

    private static func validateResultDirectory(at bundle: URL) throws {
        var directories = [bundle]
        while let directory = directories.popLast() {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) {
                let item = directory.appending(component: name, directoryHint: .notDirectory)
                let attributes = try FileManager.default.attributesOfItem(atPath: item.path(percentEncoded: false))
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: directories.append(item)
                case .typeRegular: break
                default: throw RemoteOperationFailure("Unexpected file type in the result bundle: \(name).")
                }
            }
        }
    }

    private static func unexpected(_ reply: HostLinkReply) -> HostLinkError {
        if case .refused(let message) = reply { return .refused(message) }
        return .unexpectedReply
    }
}

/// The terminal gets a bounded result. The complete list of jobs and the transcript live beside the artifacts.
struct WorkflowSummary: Codable {
    struct Job: Codable {
        var id: String?
        let name: String
        let status: String
        var allowedFailure: Bool?
        var step: String?
        var logLine: Int?
        var message: String?
    }
    let status: String
    let runner: String
    var jobs: [Job]
    var message: String?
    var jobCount: Int?
    var log: String?
    var summary: String?
    var artifacts: String?

    static func report(in folder: URL, format: WorkflowOutput, exitCode: Int32) throws -> Data {
        let file = folder.appending(path: "summary.json")
        let log = folder.appending(path: "workflow.log")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RemoteOperationFailure("Workflow exited with status \(exitCode) before writing its summary. Log: \(log.path)")
        }
        var report = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        let count = report.jobs.count
        report.jobCount = count
        let failures = report.jobs.filter { $0.status == "failure" }
        report.jobs = Array((failures + report.jobs.filter { $0.status != "failure" }).prefix(12))
        report.summary = file.path
        report.log = log.path
        let artifacts = folder.appending(path: "artifacts")
        if FileManager.default.fileExists(atPath: artifacts.path) { report.artifacts = artifacts.path }
        if format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(report) + Data([10])
        }
        var lines = ["Workflow \(report.status) on \(report.runner) (\(count) jobs)."]
        if let message = report.message { lines.append(message) }
        for job in report.jobs {
            let status = job.allowedFailure == true ? "allowed failure" : job.status
            lines.append("\(job.name): \(status)" + (job.step.map { " — " + $0 } ?? ""))
            if let message = job.message { lines.append(message) }
            if let line = job.logLine { lines.append("Details: " + log.path + ":\(line)") }
        }
        if count > report.jobs.count { lines.append("All jobs: " + file.path) }
        lines.append("Log: " + log.path)
        if let artifacts = report.artifacts { lines.append("Artifacts: " + artifacts) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
