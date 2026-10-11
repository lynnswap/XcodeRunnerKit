import Foundation
import Subprocess

/// Runs native Xcode operations with per-operation logs and result bundles.
public struct XcodeRunner: Sendable {
    public var developerDirectory: URL?
    public var executionPool: HostExecutionPool?
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

    /// Runs an operation and waits for execution and log cleanup.
    ///
    /// Cancellation terminates the operation's process group. Failures retain
    /// artifact locations in XcodeBuildFailure, including incomplete output.
    public func run(
        _ action: XcodeBuildAction,
        request: XcodeBuildRequest,
        onOutput: (@Sendable (Data) throws -> Void)? = nil
    ) async throws -> XcodeBuildResult {
        if let executionPool {
            return try await executionPool.withSlot {
                try await runManaged(action, request: request, onOutput: onOutput)
            }
        }
        return try await runManaged(action, request: request, onOutput: onOutput)
    }

    private func runManaged(
        _ action: XcodeBuildAction,
        request: XcodeBuildRequest,
        onOutput: (@Sendable (Data) throws -> Void)?
    ) async throws -> XcodeBuildResult {
        guard let configuration = request.simulator else {
            return try await runUnrestricted(action, request: request, onOutput: onOutput)
        }
        try Task.checkCancellation()
        let selectedXcode = developerDirectory ?? request.environment["DEVELOPER_DIR"].map { URL(filePath: $0) }
        let tool = SimulatorTool(executableURL: simulatorExecutableURL, developerDirectory: selectedXcode)
        // Finish creation even if the caller cancels, so the owned UDID is known.
        let identifier = try await Task.detached { try await tool.create(configuration) }.value
        let outcome: Result<XcodeBuildResult, any Error>
        do {
            try Task.checkCancellation()
            var simulatorRequest = request
            simulatorRequest.destination = "platform=iOS Simulator,id=" + identifier
            if !request.arguments.contains("-parallel-testing-enabled") {
                simulatorRequest.arguments = ["-parallel-testing-enabled", "NO"] + request.arguments
            }
            outcome = .success(try await runUnrestricted(
                action, request: simulatorRequest, simulatorIdentifier: identifier, onOutput: onOutput
            ))
        } catch { outcome = .failure(error) }

        // Cleanup must run after cancellation, and remains inside the host slot.
        do { try await Task.detached { try await tool.delete(identifier) }.value }
        catch {
            let operationError: (any Error)?
            let completed: XcodeBuildResult?
            switch outcome {
            case .success(let result): operationError = nil; completed = result
            case .failure(let error): operationError = error; completed = nil
            }
            throw SimulatorCleanupFailure(
                simulatorIdentifier: identifier, operationError: operationError,
                result: completed, cleanupError: error
            )
        }
        return try outcome.get()
    }

    private func runUnrestricted(
        _ action: XcodeBuildAction,
        request: XcodeBuildRequest,
        simulatorIdentifier: String? = nil,
        onOutput: (@Sendable (Data) throws -> Void)?
    ) async throws -> XcodeBuildResult {
        let directory = request.outputDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let derived = request.derivedDataDirectory ?? directory.appending(path: "DerivedData", directoryHint: .isDirectory)
        let logURL = directory.appending(path: "xcodebuild.log")
        let bundleURL = directory.appending(path: "Results.xcresult")
        var status = XcodeBuildResult.Status.executionFailed
        var executionError: (any Error)?
        var cleanupError: (any Error)?
        var log: FileHandle?

        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: logURL)
            let handle = try FileHandle(forWritingTo: logURL)
            log = handle

            var environment = request.environment
            if let developerDirectory {
                environment["DEVELOPER_DIR"] = developerDirectory.path(percentEncoded: false)
            }
            var buildSettings = request.buildSettings
            var commandSource = request.source
            var commandDerivedData = derived
            if let cache = request.compilationCache {
                try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
                commandSource = try request.source.canonicalized()
                commandDerivedData = try derived.compilerCanonicalURL()
                buildSettings = cache.buildSettings(sourceDirectory: commandSource.workingDirectory, derivedDataDirectory: commandDerivedData)
                    .merging(buildSettings) { _, caller in caller }
            }
            let arguments = [action.rawValue] + commandSource.arguments + [
                "-scheme", request.scheme,
                "-destination", request.destination,
                "-derivedDataPath", commandDerivedData.path(percentEncoded: false),
                "-resultBundlePath", bundleURL.path(percentEncoded: false),
            ] + request.arguments + buildSettings.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }

            var options = PlatformOptions()
            options.createSession = true
            // SIGINT can stop the group leader while background children ignore it.
            options.teardownSequence = [
                .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero),
            ]
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

        do { try log?.close() } catch { cleanupError = error }
        let result = XcodeBuildResult(
            status: status,
            outputDirectory: directory,
            derivedDataDirectory: derived,
            logURL: logURL,
            resultBundleURL: bundleURL,
            simulatorIdentifier: simulatorIdentifier
        )
        guard result.succeeded, cleanupError == nil else {
            throw XcodeBuildFailure(result: result, underlyingError: executionError, cleanupError: cleanupError)
        }
        return result
    }
}
