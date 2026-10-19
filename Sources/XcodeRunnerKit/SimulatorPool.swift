import CryptoKit
import Darwin
import Foundation

/// Reuses exclusively leased Simulators across cooperating processes on one Mac.
///
/// A normal test exit returns its cleaned device to the pool without shutting it
/// down. Cancelled, interrupted, or abandoned leases are retired before reuse.
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
                    let handle = try Self.open(recordURL.deletingPathExtension().appendingPathExtension("lock"))
                    try await Self.withHandle(handle) {
                        guard try Self.tryLock(handle) else { return }
                        guard let record = try Self.readRecordIfPresent(recordURL) else { return }
                        let tool = SimulatorTool(
                            executableURL: executableURL, developerDirectory: URL(filePath: key.developerDirectory),
                            inheritedLeaseDescriptor: handle.fileDescriptor
                        )
                        do {
                            try Self.saveRecord(Record(identifier: record.identifier, isReady: false), at: recordURL)
                            try await Task.detached {
                                try await tool.deleteDevices(named: Self.deviceName(for: recordURL))
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
        configuration: SimulatorConfiguration,
        developerDirectory: URL,
        tool: SimulatorTool,
        operation: @Sendable (String) async throws -> XcodeBuildResult
    ) async throws -> XcodeBuildResult {
        let key = Key(
            developerDirectory: developerDirectory.resolvingSymlinksInPath().path(percentEncoded: false),
            runtimeIdentifier: configuration.runtimeIdentifier,
            deviceTypeIdentifier: configuration.deviceTypeIdentifier
        )
        let lease = try await acquire(key: key)
        var leasedTool = tool
        leasedTool.inheritedLeaseDescriptor = lease.handle.fileDescriptor
        let protectedTool = leasedTool
        return try await Self.withHandle(lease.handle) {
            // Creation finishes even after cancellation so its identifier can be recorded.
            let identifier: String
            do {
                identifier = try await Task.detached {
                    try await Self.prepare(lease, configuration: configuration, tool: protectedTool)
                }.value
            } catch {
                let preparationError = error
                do { try await Self.retire(lease, tool: protectedTool) }
                catch {
                    throw SimulatorCleanupFailure(
                        simulatorIdentifier: lease.record.identifier ?? Self.deviceName(for: lease.recordURL),
                        operationError: preparationError, result: nil, cleanupError: error
                    )
                }
                throw preparationError
            }
            let outcome: Result<XcodeBuildResult, any Error>
            do {
                try Task.checkCancellation()
                try await protectedTool.boot(identifier)
                outcome = .success(try await operation(identifier))
            } catch { outcome = .failure(error) }

            let reuse = !Task.isCancelled && Self.canReuse(after: outcome)
            do {
                // The lease stays locked until cancellation-independent cleanup finishes.
                try await Task.detached {
                    if reuse {
                        try await protectedTool.prepareForReuse(identifier)
                        try Self.saveRecord(Record(identifier: identifier, isReady: true), at: lease.recordURL)
                    } else {
                        try await protectedTool.deleteDevices(named: Self.deviceName(for: lease.recordURL))
                        try FileManager.default.removeItem(at: lease.recordURL)
                    }
                }.value
                if reuse, Task.isCancelled {
                    try Self.saveRecord(Record(identifier: identifier, isReady: false), at: lease.recordURL)
                    try await Self.retire(lease, tool: protectedTool)
                }
            } catch {
                var cleanupError = error
                if reuse {
                    do { try await Self.retire(lease, tool: protectedTool) }
                    catch {
                        cleanupError = SimulatorCleanupFailure(
                            simulatorIdentifier: identifier, operationError: cleanupError,
                            result: nil, cleanupError: error
                        )
                    }
                }
                let operationError: (any Error)?
                let result: XcodeBuildResult?
                switch outcome {
                case .success(let completed): operationError = nil; result = completed
                case .failure(let failure): operationError = failure; result = nil
                }
                throw SimulatorCleanupFailure(
                    simulatorIdentifier: identifier, operationError: operationError,
                    result: result, cleanupError: cleanupError
                )
            }
            let result = try outcome.get()
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
                let handle = try Self.open(recordURL.deletingPathExtension().appendingPathExtension("lock"))
                do {
                    if try Self.tryLock(handle), let record = try Self.readRecordIfPresent(recordURL) {
                        // A free dirty record means the previous owner did not finish cleanup.
                        try Self.saveRecord(Record(identifier: record.identifier, isReady: false), at: recordURL)
                        return Lease(recordURL: recordURL, record: record, handle: handle)
                    }
                } catch { return try await Self.withHandle(handle) { throw error } }
                try handle.close()
            }
            let recordURL = keyDirectory.appending(path: "device-\(UUID().uuidString).json")
            let handle = try Self.open(recordURL.deletingPathExtension().appendingPathExtension("lock"))
            do {
                try await Self.lock(handle)
                let record = Record(identifier: nil, isReady: false)
                // The name is durable before simctl runs, including its unknown-UDID window.
                try Self.saveRecord(record, at: recordURL)
                return Lease(recordURL: recordURL, record: record, handle: handle)
            } catch { return try await Self.withHandle(handle) { throw error } }
        }
    }

    private static func prepare(_ lease: Lease, configuration: SimulatorConfiguration, tool: SimulatorTool) async throws -> String {
        if lease.record.isReady, let identifier = lease.record.identifier,
           try await tool.containsDevice(identifier) { return identifier }
        let name = deviceName(for: lease.recordURL)
        try await tool.deleteDevices(named: name)
        try saveRecord(Record(identifier: nil, isReady: false), at: lease.recordURL)
        let identifier = try await tool.create(configuration, name: name)
        try saveRecord(Record(identifier: identifier, isReady: false), at: lease.recordURL)
        return identifier
    }

    private static func retire(_ lease: Lease, tool: SimulatorTool) async throws {
        try await Task.detached {
            try await tool.deleteDevices(named: deviceName(for: lease.recordURL))
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
