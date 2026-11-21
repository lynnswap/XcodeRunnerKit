import CryptoKit
import Foundation
import Network
import Subprocess
import XcodeRunnerHostSupport
import XcodeRunnerKit

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
        _ operation: RemoteOperation, for dashboard: HostPairing.ID, slot: Int32? = nil, labels: [String] = [],
        next: @escaping @Sendable () async throws -> HostLinkRequest,
        reply: @escaping @Sendable (HostLinkReply) async throws -> Void
    ) async throws {
        guard let storage else {
            throw HostAvailability.unavailable("\(HostPane.macName) has not prepared its storage.")
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
        let executable: URL
        let arguments: [String]
        var hostEnvironment = installation.environment(for: storage)
        if let workflow = operation.workflow {
            guard slot != nil, let script = Bundle.module.url(forResource: "run-workflow", withExtension: "py") else {
                throw HostAvailability.unavailable("This host could not start the workflow.")
            }
            executable = URL(filePath: "/usr/bin/python3")
            arguments = [script.path, workflowEngine.path, checkout.path, output.path, workflow.file,
                         workflow.event, workflow.repository, workflow.sha, workflow.ref, workflow.base, workflow.output.rawValue, HostPane.macName] + labels
            if let developer = try installation.developerDirectory() { hostEnvironment["DEVELOPER_DIR"] = developer.path }
        } else {
            executable = tool
            let cache = storage.compilationCacheDirectory.appending(path: "remote")
            arguments = [operation.action, "--output-directory=\(output.path(percentEncoded: false))",
                         "--compilation-cache=\(cache.path(percentEncoded: false))"]
                + (slot.map { ["--reserved-slot=\($0)"] } ?? []) + operation.arguments
        }
        let environment = hostEnvironment
        // The dashboard sends the whole checkout once this Mac accepts, so what can refuse the operation comes first.
        do {
            try await Self.requireStorage(storage)
            // An operation that the host did not finish, as when it quit, left its checkout.
            try await Self.remove(folder)
        } catch {
            throw HostAvailability.unavailable(error.localizedDescription)
        }
        try await reply(.operation(.accepted(
            checkoutDirectory: checkout.path(percentEncoded: false), outputDirectory: output.path(percentEncoded: false)
        )))
        do {
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
                    if slot != nil, operation.workflow?.output != .json { try await reply(.operation(.output(Data("Running on \(HostPane.macName)\n".utf8)))) }
                    try await Self.execute(
                        operation, in: checkout, output: output, tool: executable, arguments: arguments, environment: environment,
                        slot: operation.workflow == nil ? slot : nil, reply: reply
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

    @concurrent nonisolated static func requireStorage(_ storage: HostInstallation.Storage) async throws {
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

    private var workflowEngine: URL { installation.hostRoot.appending(path: "WorkflowEngine/act-0.2.98-xrk3/xrk-act") }

    func labels(for workflow: WorkflowInvocation) async throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: workflowEngine.path) else {
            throw HostAvailability.unavailable("Install the workflow engine on this Mac with Scripts/install-workflow-engine.sh.")
        }
        var labels = try installation.runnerLabels() + ["macOS", "macos-latest", "self-hosted", "xcode-runnerkit"]
        #if arch(arm64)
        labels.append("arm64")
        #else
        labels.append("x64")
        #endif
        let environment: Subprocess.Environment = try installation.developerDirectory().map {
            .inherit.updating(["DEVELOPER_DIR": $0.path])
        } ?? .inherit
        let xcode = try await Subprocess.run(.path("/usr/bin/xcodebuild"), arguments: ["-version"], environment: environment,
                                             output: .string(limit: 4096), error: .string(limit: 4096))
        guard xcode.terminationStatus.isSuccess else { throw RemoteOperationFailure(xcode.standardError) }
        if let version = xcode.standardOutput.split(whereSeparator: { $0.isWhitespace }).dropFirst().first,
           let major = version.split(separator: ".").first { labels.append("xcode-" + major) }
        guard let script = Bundle.module.url(forResource: "run-workflow", withExtension: "py") else {
            throw RemoteOperationFailure("The workflow helper is missing.")
        }
        let encoded = try JSONEncoder().encode(workflow)
        let plan = try await Subprocess.run(.path("/usr/bin/python3"),
            arguments: .init([script.path, "plan", workflowEngine.path] + labels),
            environment: environment, input: .string(String(decoding: encoded, as: UTF8.self)),
            output: .string(limit: 1 << 20), error: .string(limit: 4096))
        guard plan.terminationStatus.isSuccess else {
            throw HostAvailability.unavailable((plan.standardOutput + plan.standardError).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return labels
    }

    /// Runs the command in the checkout and sends its output, its exit status, and its log and result bundles.
    @concurrent private nonisolated static func execute(
        _ operation: RemoteOperation, in checkout: URL, output: URL, tool: URL, arguments: [String], environment: [String: String], slot: Int32?,
        reply: @Sendable (HostLinkReply) async throws -> Void
    ) async throws {
        var options = PlatformOptions()
        // Asked to end, the tool stops its build, returns its Simulator, and frees its place in the job limit.
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(30))]
        // The host's folders come first, so that they are options even when the operation passes arguments to
        // xcodebuild after "--".
        if let slot {
            options.preSpawnProcessConfigurator = { _, actions in
                let code = posix_spawn_file_actions_addinherit_np(&actions, slot)
                guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            }
        }
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
        var results: [String] = []
        for job in try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false)) {
            let directory = output.appending(component: job, directoryHint: .notDirectory)
            try RemoteOperation.requireResultType(.typeDirectory, at: directory)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) {
                let type: FileAttributeType
                if name == "xcodebuild.log" || (operation.workflow != nil && ["workflow.log", "summary.json"].contains(name)) { type = .typeRegular }
                else if name.hasSuffix(".xcresult") || (operation.workflow != nil && name == "artifacts") { type = .typeDirectory }
                else { continue }
                try RemoteOperation.requireResultType(type, at: directory.appending(component: name, directoryHint: .notDirectory))
                results.append("./" + job + "/" + name)
            }
        }
        guard !results.isEmpty else { return }
        let archive = try await Subprocess.run(
            .path("/usr/bin/tar"), arguments: .init(["-cf", "-", "--no-mac-metadata", "--no-xattrs", "-C", output.path(percentEncoded: false)] + results),
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

extension RemoteOperation {
    /// Inspects the directory entry itself before opening a build log or enumerating a job folder.
    static func requireResultType(_ type: FileAttributeType, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard attributes[.type] as? FileAttributeType == type else {
            throw RemoteOperationFailure("Unexpected file type in the build results: \(url.lastPathComponent).")
        }
    }
}

/// Outcomes for which no checkout has been sent and another Mac can still take the job.
enum HostAvailability: Error {
    case needsRuntimeDownload
    case busy
    case unavailable(String)
}

extension HostSettingsModel {
    /// Try this Mac and then the Macs it manages. A manager sends each worker a single-host request,
    /// so a forwarded operation never travels on to another pool.
    func dispatch(
        _ operation: RemoteOperation, from dashboard: HostPairing.ID, includingManagedMacs: Bool, allowRuntimeDownload: Bool,
        next: @escaping @Sendable () async throws -> HostLinkRequest,
        reply: @escaping @Sendable (HostLinkReply) async throws -> Void
    ) async throws {
        var busy = false
        var needsDownload = false
        var reasons: [String] = []
        var labels: [String] = []
        let reservation: HostExecutionPool.Reservation?
        do {
            guard !isPaused else { throw RemoteOperationFailure("Paused.") }
            guard let storage = operations.storage else { throw RemoteOperationFailure("Storage unavailable.") }
            try await RemoteOperations.requireStorage(storage)
            if let workflow = operation.workflow {
                labels = try await operations.labels(for: workflow)
            } else {
                labels = []
                try await operation.checkDestination(savedXcode: installation.developerDirectory(), allowRuntimeDownload: allowRuntimeDownload)
            }
            reservation = try await pool.reserveAvailableSlot()
            busy = reservation == nil
        } catch HostAvailability.needsRuntimeDownload {
            needsDownload = true
            reservation = nil
        } catch HostAvailability.unavailable(let reason) {
            reasons.append(reason)
            reservation = nil
        } catch {
            try Task.checkCancellation()
            reasons.append(error.localizedDescription)
            reservation = nil
        }
        if let reservation {
            let matchedLabels = labels
            do {
                try await reservation.withDescriptor { descriptor in
                    guard await !self.isPaused else { throw HostAvailability.unavailable("Paused.") }
                    try await self.operations.run(operation, for: dashboard, slot: descriptor, labels: matchedLabels, next: next, reply: reply)
                }
                return
            } catch HostAvailability.unavailable(let reason) {
                reasons.append(reason)
            }
        }
        if includingManagedMacs {
            // The worker knows only its manager's pairing. Keep different dashboards' checkout folders distinct.
            let forwarded = RemoteOperation(
                repository: "\(dashboard.uuidString)/\(operation.repository)", name: operation.name,
                directory: operation.directory, action: operation.action, arguments: operation.arguments, workflow: operation.workflow
            )
            for mac in managedMacs.macs {
                guard let endpoint = managedMacs.endpoint(for: mac) else {
                    reasons.append("\(mac.name) is offline.")
                    continue
                }
                do {
                    try await RemoteOperations.forward(
                        forwarded, to: mac, at: endpoint, allowRuntimeDownload: allowRuntimeDownload, next: next, reply: reply
                    )
                    return
                } catch HostAvailability.needsRuntimeDownload {
                    needsDownload = true
                } catch HostAvailability.busy {
                    busy = true
                } catch HostAvailability.unavailable(let reason) {
                    reasons.append("\(mac.name): \(reason)")
                }
            }
        }
        if needsDownload { try await reply(.operation(.needsRuntimeDownload)) }
        else if busy { try await reply(.operation(.busy)) }
        else { try await reply(.operation(.unavailable(reasons.joined(separator: " ")))) }
    }
}

extension RemoteOperations {
    /// Bridge the selected worker's connection for the lifetime of the job. After acceptance a failed
    /// transfer or build is final, since the worker may have already started it.
    nonisolated static func forward(
        _ operation: RemoteOperation, to mac: PairedMac, at endpoint: NWEndpoint, allowRuntimeDownload: Bool,
        next: @escaping @Sendable () async throws -> HostLinkRequest,
        reply: @escaping @Sendable (HostLinkReply) async throws -> Void
    ) async throws {
        let request: RemoteOperationRequest = operation.action == "workflow" ? .workflow(operation, dispatch: false)
            : .startIfAvailable(operation, allowRuntimeDownload: allowRuntimeDownload)
        try await RemoteOperationClient.exchange(request, with: mac, at: endpoint) { accepted, worker in
            try await reply(accepted)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    files: while true {
                        switch try await next() {
                        case .operation(.files(let data)): try await worker.send(.operation(.files(data)))
                        case .operation(.filesEnd):
                            try await worker.send(.operation(.filesEnd))
                            break files
                        default: throw HostLinkError.unexpectedReply
                        }
                    }
                    guard case .operation(.received) = try await next() else { throw HostLinkError.unexpectedReply }
                    try await worker.send(.operation(.received))
                }
                group.addTask {
                    while true {
                        let event = try await worker.receive()
                        switch event {
                        case .operation(.output), .operation(.exited), .operation(.results):
                            try await reply(event)
                        case .operation(.finished):
                            try await reply(event)
                            return
                        case .refused(let message):
                            try await reply(event)
                            throw RemoteOperationFailure(message)
                        default: throw HostLinkError.unexpectedReply
                        }
                    }
                }
                defer { group.cancelAll() }
                while try await group.next() != nil {}
            }
        }
    }
}

extension RemoteOperation {
    /// The dashboard joins each option to its value, except for empty values, which ArgumentParser reads separately.
    func checkDestination(savedXcode: URL?, allowRuntimeDownload: Bool) async throws {
        let options = arguments.prefix { $0 != "--" }
        func value(_ key: String) -> String? {
            for index in options.indices.reversed() {
                let argument = options[index]
                if argument.hasPrefix(key) { return String(argument.dropFirst(key.count)) }
                if argument == key.dropLast(), options.dropFirst(index + 1).first == "" { return "" }
            }
            return nil
        }
        let explicitDirectory = value("--developer-directory=")
        let runtime = value("--simulator-runtime=")
        let developer = explicitDirectory ?? value("--environment=DEVELOPER_DIR=")
            ?? ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? savedXcode?.path(percentEncoded: false)
        let environment: Subprocess.Environment = developer.map { .inherit.updating(["DEVELOPER_DIR": $0]) } ?? .inherit
        func xcrun(_ arguments: [String]) async throws -> Data {
            let result = try await Subprocess.run(
                .path("/usr/bin/xcrun"), arguments: .init(arguments), environment: environment,
                output: .bytes(limit: .max), error: .string(limit: .max)
            )
            guard result.terminationStatus.isSuccess else { throw RemoteOperationFailure(result.standardError) }
            return Data(result.standardOutput)
        }
        // The CLI resolves an explicit path against its checkout, as does a managed Simulator's
        // DEVELOPER_DIR. For other destinations xcrun interprets an empty environment value itself.
        if let developer, !developer.hasPrefix("/"),
           explicitDirectory != nil || runtime != nil || !developer.isEmpty { return }
        _ = try await xcrun(["--find", "xcodebuild"])
        if let runtime, let type = value("--simulator-device-type=") {
            struct DeviceType: Decodable { let identifier: String }
            struct Runtime: Decodable {
                let identifier: String
                let isAvailable: Bool
                let supportedDeviceTypes: [DeviceType]
            }
            struct Listing: Decodable {
                let runtimes: [Runtime]
                let devicetypes: [DeviceType]
            }
            let listing = try JSONDecoder().decode(Listing.self, from: try await xcrun(["simctl", "list", "--json"]))
            if let installed = listing.runtimes.first(where: { $0.identifier == runtime }) {
                guard installed.isAvailable, installed.supportedDeviceTypes.contains(where: { $0.identifier == type }) else {
                    throw RemoteOperationFailure("The installed \(runtime) runtime cannot run \(type).")
                }
            } else {
                guard SimulatorConfiguration.downloadArguments(forRuntime: runtime) != nil else {
                    throw RemoteOperationFailure("This Mac has no installed \(runtime) runtime and cannot download it by identifier.")
                }
                guard listing.devicetypes.contains(where: { $0.identifier == type }) else {
                    throw RemoteOperationFailure("This Xcode has no \(type) device type.")
                }
                guard allowRuntimeDownload else { throw HostAvailability.needsRuntimeDownload }
            }
            return
        }
        guard let specifier = value("--destination=") else { return }
        var fields: [String: String] = [:]
        for pair in specifier.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        let platforms = ["macOS": "macosx", "iOS": "iphoneos", "iOS Simulator": "iphonesimulator",
                         "tvOS": "appletvos", "tvOS Simulator": "appletvsimulator", "watchOS": "watchos",
                         "watchOS Simulator": "watchsimulator", "visionOS": "xros", "visionOS Simulator": "xrsimulator"]
        if let generic = fields["generic/platform"], let sdk = platforms[generic] {
            _ = try await xcrun(["--sdk", sdk, "--show-sdk-path"])
            return
        }
        if fields["platform"] == "macOS", fields["id"] == nil, fields["OS"] == nil,
           fields["name"] == nil || fields["name"] == "My Mac" {
            #if arch(arm64)
            if fields["arch"] == nil || fields["arch"] == "arm64" { return }
            #endif
        }
        struct Device: Decodable {
            let identifier: String
            let platform: String
            let name: String
            let available: Bool
            let operatingSystemVersion: String?
            let architecture: String?
        }
        let devices = try JSONDecoder().decode([Device].self, from: try await xcrun(["xcdevice", "list", "--timeout", "1"]))
        let platform = fields["platform"].flatMap { platforms[$0] }
        guard devices.contains(where: { device in
            device.available && platform.map { device.platform == "com.apple.platform." + $0 } != false
                && fields["id"].map { device.identifier.caseInsensitiveCompare($0) == .orderedSame } != false
                && fields["name"].map { device.name == $0 || ($0 == "My Mac" && device.platform == "com.apple.platform.macosx") } != false
                && fields["arch"].map { device.architecture == $0 } != false
                && fields["OS"].map { $0 == "latest" || device.operatingSystemVersion?.split(separator: " ").first.map(String.init) == $0 } != false
        }) else { throw RemoteOperationFailure("No available destination matching \(specifier).") }
    }
}
