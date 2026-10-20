import Darwin
import Foundation
import Subprocess

/// Runs native Xcode operations with per-operation logs and result bundles.
public struct XcodeRunner: Sendable {
    public var developerDirectory: URL?
    /// A custom build service executable, overriding inherited service selection.
    ///
    /// The path is passed directly to each xcodebuild child process. It does not
    /// require a launchd environment setting or restarting the calling process.
    public var buildServiceExecutableURL: URL?
    public var executionPool: HostExecutionPool?
    /// A shared Simulator pool. When nil, runs use executionPool.simulatorPool,
    /// or SimulatorPool.defaultDirectory when no execution pool is configured.
    public var simulatorPool: SimulatorPool?
    private let executableURL: URL
    private var simulatorExecutableURL = URL(filePath: "/usr/bin/xcrun")

    public init(developerDirectory: URL? = nil) {
        self.developerDirectory = developerDirectory
        self.executableURL = URL(filePath: "/usr/bin/xcodebuild")
    }

    init(executableURL: URL, developerDirectory: URL? = nil, simulatorExecutableURL: URL = URL(filePath: "/usr/bin/xcrun")) {
        self.executableURL = executableURL
        self.developerDirectory = developerDirectory
        self.simulatorExecutableURL = simulatorExecutableURL
    }

    /// Runs an operation and waits for execution and cleanup.
    ///
    /// Throws XcodeBuildFailure for every unsuccessful operation, including
    /// cancellation, failures before xcodebuild starts, and cleanup failures.
    /// Cancellation terminates the operation's process group. Failures retain
    /// the job's artifact locations once its directory exists, including
    /// incomplete output. Priority orders waiting operations when an
    /// executionPool is configured.
    public func run(
        _ action: XcodeBuildAction,
        request: XcodeBuildRequest,
        priority: HostExecutionPool.Priority = .medium,
        onOutput: (@Sendable (Data) throws -> Void)? = nil
    ) async throws -> XcodeBuildResult {
        guard let executionPool else {
            return try await runManaged(action, request: request, onOutput: onOutput).get()
        }
        let slot = await executionPool.slotOutcome(priority: priority) {
            await runManaged(action, request: request, onOutput: onOutput)
        }
        let outcome: XcodeBuildOutcome
        switch slot.value {
        case .success(let operation): outcome = operation
        case .failure(let error): outcome = .failure(wrapping: error)
        }
        return try outcome.addingCleanupErrors(slot.cleanupErrors).get()
    }

    private func runManaged(
        _ action: XcodeBuildAction,
        request: XcodeBuildRequest,
        onOutput: (@Sendable (Data) throws -> Void)?
    ) async -> XcodeBuildOutcome {
        let configuration: SimulatorConfiguration
        switch request.destination {
        case .specifier(let destination):
            return await runUnrestricted(action, request: request, destination: destination, onOutput: onOutput)
        case .managedSimulator(let managed):
            configuration = managed
        }
        let tool: SimulatorTool
        let selectedXcode: URL
        do {
            try Task.checkCancellation()
            selectedXcode = try await SimulatorTool.selectedDeveloperDirectory(
                developerDirectory ?? (request.environment["DEVELOPER_DIR"] ?? ProcessInfo.processInfo.environment["DEVELOPER_DIR"])
                    .map { URL(filePath: $0) }
            )
            tool = SimulatorTool(executableURL: simulatorExecutableURL, developerDirectory: selectedXcode)
        } catch {
            return .failure(wrapping: error)
        }
        var selectedRequest = request
        selectedRequest.environment["DEVELOPER_DIR"] = selectedXcode.path(percentEncoded: false)
        let simulatorRequest = selectedRequest
        if configuration.reusesDevice {
            let pool = simulatorPool ?? executionPool?.simulatorPool ?? SimulatorPool()
            return await pool.withSimulator(action: action, configuration: configuration, developerDirectory: selectedXcode, tool: tool) { identifier, leaseDescriptor in
                await runOnSimulator(
                    action, request: simulatorRequest, identifier: identifier,
                    inheritedLeaseDescriptor: leaseDescriptor, onOutput: onOutput
                )
            }
        }
        let name = SimulatorTool.freshDeviceName()
        let identifier: String
        // Finish creation even if the caller cancels, so the owned UDID is known.
        do { identifier = try await Task.detached { try await tool.create(configuration, name: name) }.value }
        catch { return .failure(wrapping: error) }
        var outcome: XcodeBuildOutcome
        do {
            try Task.checkCancellation()
            if action == .test || action == .testWithoutBuilding {
                try await tool.boot(identifier)
            }
            outcome = await runOnSimulator(action, request: simulatorRequest, identifier: identifier, onOutput: onOutput)
        } catch {
            outcome = .failure(wrapping: error)
        }

        // Cleanup must run after cancellation, and remains inside the host slot.
        var cleanupErrors: [any Error] = []
        do { try await Task.detached { try await tool.delete(identifier) }.value }
        catch {
            cleanupErrors.append(SimulatorCleanupFailure(simulatorIdentifier: identifier, simulatorName: name, underlyingError: error))
        }
        return outcome.cancelledIfNeeded().addingCleanupErrors(cleanupErrors)
    }

    private func runOnSimulator(
        _ action: XcodeBuildAction, request: XcodeBuildRequest, identifier: String,
        inheritedLeaseDescriptor: Int32? = nil,
        onOutput: (@Sendable (Data) throws -> Void)?
    ) async -> XcodeBuildOutcome {
        var simulatorRequest = request
        if !request.arguments.contains("-parallel-testing-enabled") {
            simulatorRequest.arguments = ["-parallel-testing-enabled", "NO"] + request.arguments
        }
        // The UDID alone selects the device, whatever platform its runtime belongs to.
        return await runUnrestricted(
            action, request: simulatorRequest, destination: "id=" + identifier, simulatorIdentifier: identifier,
            inheritedLeaseDescriptor: inheritedLeaseDescriptor, onOutput: onOutput
        )
    }

    private func runUnrestricted(
        _ action: XcodeBuildAction,
        request: XcodeBuildRequest,
        destination: String,
        simulatorIdentifier: String? = nil,
        inheritedLeaseDescriptor: Int32? = nil,
        onOutput: (@Sendable (Data) throws -> Void)?
    ) async -> XcodeBuildOutcome {
        let directory = request.outputDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let derived = request.derivedDataDirectory ?? directory.appending(path: "DerivedData", directoryHint: .isDirectory)
        let logURL = directory.appending(path: "xcodebuild.log")
        let bundleURL = directory.appending(path: "Results.xcresult")
        do {
            try Task.checkCancellation()
            try Self.createDirectory(request.outputDirectory, ifMissing: true)
            try Self.createDirectory(directory, ifMissing: false)
        } catch {
            return .failure(wrapping: error)
        }

        var status = XcodeBuildResult.Status.executionFailed
        var executionError: (any Error)?
        var cleanupErrors: [any Error] = []
        var log: FileHandle?
        do {
            try Data().write(to: logURL)
            let handle = try FileHandle(forWritingTo: logURL)
            log = handle

            var environment = request.environment
            if let developerDirectory {
                environment["DEVELOPER_DIR"] = developerDirectory.path(percentEncoded: false)
            }
            if let buildServiceExecutableURL {
                environment["SWBBUILDSERVICE_PATH"] = buildServiceExecutableURL.path(percentEncoded: false)
            }
            var buildSettings = request.buildSettings
            var commandSource = request.source
            var commandDerivedData = derived
            if let cache = request.compilationCache {
                try Self.createDirectory(cache.directory, ifMissing: true)
                try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: request.derivedDataDirectory != nil)
                commandSource = try request.source.canonicalized()
                commandDerivedData = try derived.compilerCanonicalURL()
                buildSettings = cache.buildSettings(sourceDirectory: commandSource.workingDirectory, derivedDataDirectory: commandDerivedData)
                    .merging(buildSettings) { _, caller in caller }
            }
            let arguments = [action.rawValue] + commandSource.arguments + [
                "-scheme", request.scheme,
                "-destination", destination,
                "-derivedDataPath", commandDerivedData.path(percentEncoded: false),
                "-resultBundlePath", bundleURL.path(percentEncoded: false),
            ] + request.arguments + buildSettings.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }

            var options = PlatformOptions()
            options.createSession = true
            // SIGINT can stop the group leader while background children ignore it.
            options.teardownSequence = [
                .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero),
            ]
            if let inheritedLeaseDescriptor {
                // A surviving xcodebuild must retain its Simulator lease after its parent exits.
                options.preSpawnProcessConfigurator = { _, fileActions in
                    let error = posix_spawn_file_actions_addinherit_np(&fileActions, inheritedLeaseDescriptor)
                    guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
                }
            }
            let execution = try await Subprocess.run(
                .path(.init(executableURL.path(percentEncoded: false))),
                arguments: .init(arguments),
                environment: .inherit.updating(Dictionary(uniqueKeysWithValues: environment.map { (Environment.Key(stringLiteral: $0.key), Optional($0.value)) })),
                workingDirectory: .init(commandSource.workingDirectory.path(percentEncoded: false)),
                platformOptions: options,
                input: .none,
                output: .sequence,
                error: .combinedWithOutput
            ) { execution in
                for try await buffer in execution.standardOutput {
                    let data = buffer.withUnsafeBytes { Data($0) }
                    try handle.write(contentsOf: data)
                    try onOutput?(data)
                }
            }
            switch execution.terminationStatus {
            case .exited(let code): status = .exited(code)
            case .signaled(let signal): status = .terminated(signal)
            }
            if Task.isCancelled { status = .cancelled }
        } catch {
            status = Task.isCancelled ? .cancelled : .executionFailed
            executionError = error
        }

        do { try log?.close() } catch { cleanupErrors.append(error) }
        let result = XcodeBuildResult(
            status: status,
            jobDirectory: directory,
            derivedDataDirectory: derived,
            logURL: logURL,
            resultBundleURL: bundleURL,
            simulatorIdentifier: simulatorIdentifier
        )
        guard result.succeeded else {
            return .failure(XcodeBuildFailure(result: result, underlyingError: executionError, cleanupErrors: cleanupErrors))
        }
        return XcodeBuildOutcome.success(result).addingCleanupErrors(cleanupErrors)
    }

    /// Creates a user-only directory without creating missing ancestors.
    ///
    /// Running at execution time, after any wait for a pool slot, this fails the
    /// operation when a removable volume holding the parent has gone, instead of
    /// recreating its folders on the startup volume.
    private static func createDirectory(_ url: URL, ifMissing: Bool) throws {
        guard mkdir(url.path(percentEncoded: false), 0o700) != 0 else { return }
        let code = errno
        if ifMissing && code == EEXIST { return }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSURLErrorKey: url])
    }
}
