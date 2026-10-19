import CryptoKit
import Darwin
import Foundation

/// Reuses exclusively leased Simulators across cooperating processes on one Mac.
///
/// A normal test exit returns its cleaned device to the pool without shutting it
/// down. Builds reuse their destination without booting or changing runtime state.
/// Cancelled, interrupted, or abandoned leases are retired before reuse.
/// Keep the directory and its lock files in place while clients are running.
public struct SimulatorPool: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        HostInstallation().poolDirectory.appending(path: "Simulators")
    }

    public init(directory: URL = Self.defaultDirectory) {
        self.directory = directory.resolvingSymlinksInPath()
    }

    /// Deletes this pool's idle devices, including abandoned devices.
    ///
    /// Active leases are skipped. Pass a developer directory to restrict cleanup
    /// to devices registered with that Xcode; otherwise all registered Xcodes are used.
    public func removeIdleSimulators(developerDirectory: URL? = nil) async throws {
        try await removeIdleSimulators(developerDirectory: developerDirectory, executableURL: URL(filePath: "/usr/bin/xcrun"))
    }

    func removeIdleSimulators(developerDirectory: URL? = nil, executableURL: URL) async throws {
        let selected = developerDirectory?.resolvingSymlinksInPath().path(percentEncoded: false)
        let keys: [URL]
        do { keys = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        for keyDirectory in keys.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            guard try keyDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let coordinator = try Self.open(keyDirectory.appending(path: "pool.lock"))
            try await Self.withHandle(coordinator) {
                try await Self.lock(coordinator)
                let key: Key
                do { key = try JSONDecoder().decode(Key.self, from: Data(contentsOf: keyDirectory.appending(path: "configuration.json"))) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
                if let selected, selected != key.developerDirectory { return }
                for recordURL in try Self.recordURLs(in: keyDirectory) {
                    try Task.checkCancellation()
                    guard let handles = try await Self.tryAcquireHandles(for: recordURL) else { continue }
                    try await Self.withHandles(handles) {
                        guard let record = try Self.readRecordIfPresent(recordURL) else { return }
                        let tool = SimulatorTool(
                            executableURL: executableURL, developerDirectory: URL(filePath: key.developerDirectory),
                            inheritedLeaseDescriptor: handles.processHandle.fileDescriptor
                        )
                        do {
                            try Self.saveRecord(Record(identifier: record.identifier, isReady: false), at: recordURL)
                            try await Task.detached {
                                try await tool.delete(identifier: record.identifier, name: Self.deviceName(for: recordURL))
                                try FileManager.default.removeItem(at: recordURL)
                            }.value
                        } catch {
                            throw SimulatorCleanupFailure(
                                simulatorIdentifier: record.identifier ?? Self.deviceName(for: recordURL),
                                operationError: nil, result: nil, cleanupError: error
                            )
                        }
                    }
                }
            }
        }
    }

    func withSimulator(
        action: XcodeBuildAction,
        configuration: SimulatorConfiguration,
        developerDirectory: URL,
        tool: SimulatorTool,
        operation: @Sendable (String, Int32) async throws -> XcodeBuildResult
    ) async throws -> XcodeBuildResult {
        let key = Key(
            developerDirectory: developerDirectory.resolvingSymlinksInPath().path(percentEncoded: false),
            runtimeIdentifier: configuration.runtimeIdentifier,
            deviceTypeIdentifier: configuration.deviceTypeIdentifier
        )
        let lease = try await acquire(key: key)
        let runsTests = action == .test || action == .testWithoutBuilding
        return try await Self.withHandle(lease.handle) {
            let execution = try await Self.withHandle(lease.processHandle) {
                var executionTool = tool
                executionTool.inheritedLeaseDescriptor = lease.processHandle.fileDescriptor
                let protectedTool = executionTool
                // Creation finishes even after cancellation so its identifier can be recorded.
                let identifier: String
                do {
                    identifier = try await Task.detached {
                        try await Self.prepare(lease, configuration: configuration, tool: protectedTool)
                    }.value
                } catch {
                    return Execution(identifier: nil, outcome: .failure(error))
                }
                let outcome: Result<XcodeBuildResult, any Error>
                do {
                    try Task.checkCancellation()
                    if runsTests { try await protectedTool.boot(identifier) }
                    outcome = .success(try await operation(identifier, lease.processHandle.fileDescriptor))
                } catch { outcome = .failure(error) }
                return Execution(identifier: identifier, outcome: outcome)
            }

            // A separate open description waits for inherited holders after ours closes.
            // The parent-only guard prevents another owner from taking this entry meanwhile.
            let cleanupHandle: FileHandle
            do { cleanupHandle = try Self.open(Self.processLockURL(for: lease.recordURL)) }
            catch {
                throw Self.cleanupFailure(lease, execution: execution, error: error)
            }
            return try await Self.withHandle(cleanupHandle) {
                do { try await Task.detached { try await Self.lock(cleanupHandle) }.value }
                catch { throw Self.cleanupFailure(lease, execution: execution, error: error) }
                var cleanupTool = tool
                cleanupTool.inheritedLeaseDescriptor = cleanupHandle.fileDescriptor
                return try await Self.finish(
                    lease, execution: execution, runsTests: runsTests, tool: cleanupTool
                )
            }
        }
    }

    private struct Execution: Sendable {
        let identifier: String?
        let outcome: Result<XcodeBuildResult, any Error>
    }

    private static func finish(
        _ lease: Lease, execution: Execution, runsTests: Bool, tool: SimulatorTool
    ) async throws -> XcodeBuildResult {
        let reuse = execution.identifier != nil && !Task.isCancelled && canReuse(after: execution.outcome)
        do {
            if reuse, let identifier = execution.identifier {
                try await Task.detached {
                    if runsTests { try await tool.prepareForReuse(identifier) }
                    try saveRecord(Record(identifier: identifier, isReady: true), at: lease.recordURL)
                }.value
            } else {
                try await retire(lease, identifier: execution.identifier, tool: tool)
            }
            if reuse, Task.isCancelled {
                try saveRecord(Record(identifier: execution.identifier, isReady: false), at: lease.recordURL)
                try await retire(lease, identifier: execution.identifier, tool: tool)
            }
        } catch {
            var cleanupError = error
            if reuse {
                do { try await retire(lease, identifier: execution.identifier, tool: tool) }
                catch {
                    cleanupError = SimulatorCleanupFailure(
                        simulatorIdentifier: execution.identifier ?? deviceName(for: lease.recordURL),
                        operationError: cleanupError, result: nil, cleanupError: error
                    )
                }
            }
            throw cleanupFailure(lease, execution: execution, error: cleanupError)
        }
        let result = try execution.outcome.get()
        if Task.isCancelled {
            throw XcodeBuildFailure(
                result: XcodeBuildResult(
                    status: .cancelled, outputDirectory: result.outputDirectory,
                    derivedDataDirectory: result.derivedDataDirectory, logURL: result.logURL,
                    resultBundleURL: result.resultBundleURL, simulatorIdentifier: result.simulatorIdentifier
                ), underlyingError: CancellationError(), cleanupError: nil
            )
        }
        return result
    }

    private static func cleanupFailure(_ lease: Lease, execution: Execution, error: any Error) -> SimulatorCleanupFailure {
        let operationError: (any Error)?
        let result: XcodeBuildResult?
        switch execution.outcome {
        case .success(let completed): operationError = nil; result = completed
        case .failure(let failure): operationError = failure; result = nil
        }
        return SimulatorCleanupFailure(
            simulatorIdentifier: execution.identifier ?? lease.record.identifier ?? deviceName(for: lease.recordURL),
            operationError: operationError, result: result, cleanupError: error
        )
    }

    private struct Key: Codable, Sendable {
        let developerDirectory: String
        let runtimeIdentifier: String
        let deviceTypeIdentifier: String
    }

    private struct Record: Codable, Sendable {
        var identifier: String?
        var isReady: Bool
    }

    private struct Lease: Sendable {
        let recordURL: URL
        let record: Record
        let handle: FileHandle
        let processHandle: FileHandle
    }

    private func acquire(key: Key) async throws -> Lease {
        try Task.checkCancellation()
        let encodedKey = try JSONEncoder().encode([key.developerDirectory, key.runtimeIdentifier, key.deviceTypeIdentifier])
        let digest = SHA256.hash(data: encodedKey).map { String(format: "%02x", $0) }.joined()
        let keyDirectory = directory.appending(path: digest)
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        let coordinator = try Self.open(keyDirectory.appending(path: "pool.lock"))
        return try await Self.withHandle(coordinator) {
            try await Self.lock(coordinator)
            try JSONEncoder().encode(key).write(to: keyDirectory.appending(path: "configuration.json"), options: .atomic)
            for recordURL in try Self.recordURLs(in: keyDirectory) {
                guard let handles = try await Self.tryAcquireHandles(for: recordURL) else { continue }
                do {
                    if let record = try Self.readRecordIfPresent(recordURL) {
                        // A free dirty record means the previous owner did not finish cleanup.
                        try Self.saveRecord(Record(identifier: record.identifier, isReady: false), at: recordURL)
                        return Lease(recordURL: recordURL, record: record, handle: handles.handle, processHandle: handles.processHandle)
                    }
                } catch { return try await Self.withHandles(handles) { throw error } }
                try await Self.withHandles(handles) {}
            }
            while true {
                let recordURL = keyDirectory.appending(path: "device-\(UUID().uuidString).json")
                guard let handles = try await Self.tryAcquireHandles(for: recordURL) else { continue }
                do {
                    let record = Record(identifier: nil, isReady: false)
                    // The name is durable before simctl runs, including its unknown-UDID window.
                    try Self.saveRecord(record, at: recordURL)
                    return Lease(recordURL: recordURL, record: record, handle: handles.handle, processHandle: handles.processHandle)
                } catch { return try await Self.withHandles(handles) { throw error } }
            }
        }
    }

    private static func prepare(_ lease: Lease, configuration: SimulatorConfiguration, tool: SimulatorTool) async throws -> String {
        if lease.record.isReady, let identifier = lease.record.identifier,
           try await tool.containsDevice(identifier) { return identifier }
        let name = deviceName(for: lease.recordURL)
        try await tool.delete(identifier: lease.record.identifier, name: name)
        try saveRecord(Record(identifier: nil, isReady: false), at: lease.recordURL)
        let identifier = try await tool.create(configuration, name: name)
        try saveRecord(Record(identifier: identifier, isReady: false), at: lease.recordURL)
        return identifier
    }

    private static func retire(_ lease: Lease, identifier: String? = nil, tool: SimulatorTool) async throws {
        try await Task.detached {
            guard let record = try readRecordIfPresent(lease.recordURL) else { return }
            try await tool.delete(identifier: identifier ?? record.identifier, name: deviceName(for: lease.recordURL))
            try FileManager.default.removeItem(at: lease.recordURL)
        }.value
    }

    private static func canReuse(after outcome: Result<XcodeBuildResult, any Error>) -> Bool {
        switch outcome {
        case .success(let result):
            if case .exited = result.status { return true }
            return false
        case .failure(let error):
            if let failure = error as? XcodeBuildFailure, case .exited = failure.result.status { return true }
            return false
        }
    }

    private static func recordURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("device-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readRecordIfPresent(_ url: URL) throws -> Record? {
        do { return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private static func saveRecord(_ record: Record, at url: URL) throws {
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private static func deviceName(for recordURL: URL) -> String {
        "XcodeRunnerKit-Pool-" + recordURL.deletingPathExtension().lastPathComponent.dropFirst("device-".count)
    }

    private typealias Handles = (handle: FileHandle, processHandle: FileHandle)

    private static func processLockURL(for recordURL: URL) -> URL {
        recordURL.deletingPathExtension().appendingPathExtension("processes.lock")
    }

    private static func tryAcquireHandles(for recordURL: URL) async throws -> Handles? {
        let guardURL = recordURL.deletingPathExtension().appendingPathExtension("lock")
        guard let handle = try await tryOpenLockedHandle(guardURL) else { return nil }
        let processHandle: FileHandle?
        do { processHandle = try await tryOpenLockedHandle(processLockURL(for: recordURL)) }
        catch { return try await withHandle(handle) { throw error } }
        guard let processHandle else {
            try handle.close()
            return nil
        }
        return (handle, processHandle)
    }

    private static func tryOpenLockedHandle(_ url: URL) async throws -> FileHandle? {
        let handle = try open(url)
        let locked: Bool
        do { locked = try tryLock(handle) }
        catch { return try await withHandle(handle) { throw error } }
        if locked { return handle }
        try handle.close()
        return nil
    }

    private static func withHandles<Value: Sendable>(
        _ handles: Handles, operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withHandle(handles.handle) {
            try await withHandle(handles.processHandle, operation: operation)
        }
    }

    private static func open(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_RDWR | O_CLOEXEC | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func tryLock(_ handle: FileHandle) throws -> Bool {
        if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK { return false }
        throw posixError()
    }

    private static func lock(_ handle: FileHandle) async throws {
        while true {
            try Task.checkCancellation()
            if try tryLock(handle) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func withHandle<Value: Sendable>(
        _ handle: FileHandle, operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let outcome: Result<Value, any Error>
        do { outcome = .success(try await operation()) }
        catch { outcome = .failure(error) }
        do { try handle.close() }
        catch {
            let operationError: (any Error)?
            switch outcome {
            case .success: operationError = nil
            case .failure(let failure): operationError = failure
            }
            throw HostExecutionCleanupFailure(operationError: operationError, cleanupError: error)
        }
        return try outcome.get()
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
