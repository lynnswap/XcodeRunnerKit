import Darwin
import Foundation

/// Shares an execution limit between cooperating processes on one Mac.
///
/// Repository runners share one local directory. Its saved capacity limits new
/// operations; a caller's capacity initializes an empty pool.
/// Do not remove the directory or its lock files while jobs are running.
public struct HostExecutionPool: Sendable {
    public let directory: URL
    /// The capacity used when the pool has no saved configuration.
    public let maximumConcurrentJobs: Int

    public init(directory: URL, maximumConcurrentJobs: Int) throws {
        guard maximumConcurrentJobs > 0 else {
            throw ConfigurationError.invalidCapacity
        }
        self.directory = directory
        self.maximumConcurrentJobs = maximumConcurrentJobs
    }

    /// The configured limit and the number of slots observed in use.
    public struct Status: Sendable, Equatable, Codable {
        public let maximumConcurrentJobs: Int
        public let activeJobCount: Int
    }

    /// Reads the pool without initializing an unconfigured directory.
    ///
    /// Running operations can finish while this snapshot is being read.
    public func status() async throws -> Status? {
        let configuration: FileHandle
        do {
            configuration = try Self.open(directory.appending(path: "capacity.lock"), create: false)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
        return try await Self.withHandle(configuration) {
            try await Self.lock(configuration)
            guard let capacity = try savedCapacity(configuration: configuration) else { return nil }
            return try Status(maximumConcurrentJobs: capacity, activeJobCount: inspectSlots().activeJobCount)
        }
    }

    /// Changes the limit for subsequent slot acquisitions, including waiting operations.
    ///
    /// Operations already holding slots continue. After a decrease, waiting
    /// operations start only when the active count is below the new limit.
    public func updateMaximumConcurrentJobs(to capacity: Int) async throws {
        guard capacity > 0 else { throw ConfigurationError.invalidCapacity }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = try Self.open(directory.appending(path: "capacity.lock"))
        try await Self.withHandle(configuration) {
            try await Self.lock(configuration)
            try saveCapacity(capacity)
        }
    }

    /// Holds a host slot until the operation, including its cleanup, finishes.
    ///
    /// Waiting is cancellable. Lock or configuration failures never bypass
    /// the limit. Processes use kernel locks, so no stale PID files are needed.
    public func withSlot<Result: Sendable>(
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        while true {
            try Task.checkCancellation()
            let configuration = try Self.open(directory.appending(path: "capacity.lock"))
            let slot: FileHandle? = try await Self.withHandle(configuration) {
                try await Self.lock(configuration)
                let capacity: Int
                if let saved = try savedCapacity(configuration: configuration) {
                    capacity = saved
                } else {
                    capacity = maximumConcurrentJobs
                    try saveCapacity(capacity)
                }
                let slots = try inspectSlots()
                guard slots.activeJobCount < capacity else { return nil }
                let handle = try Self.open(directory.appending(path: "slot-\(slots.availableIndex).lock"))
                do {
                    if try Self.tryLock(handle) { return handle }
                } catch {
                    return try Self.withHandle(handle) { throw error }
                }
                try handle.close()
                return nil
            }
            if let slot {
                return try await Self.withHandle(slot) {
                    try Task.checkCancellation()
                    return try await operation()
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func savedCapacity(configuration: FileHandle) throws -> Int? {
        let stored: Data
        do {
            stored = try Data(contentsOf: directory.appending(path: "capacity"))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Older installations saved the integer in the coordinator file.
            try configuration.seek(toOffset: 0)
            stored = try configuration.readToEnd() ?? Data()
            if stored.isEmpty { return nil }
        }
        guard let value = String(data: stored, encoding: .utf8),
              let capacity = Int(value), capacity > 0 else {
            throw ConfigurationError.invalidStoredCapacity(directory: directory)
        }
        return capacity
    }

    private func saveCapacity(_ capacity: Int) throws {
        // The coordinator inode stays in place while the data is atomically replaced.
        try Data(String(capacity).utf8).write(to: directory.appending(path: "capacity"), options: .atomic)
    }

    private func inspectSlots() throws -> (activeJobCount: Int, availableIndex: Int) {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let indices = Set(entries.compactMap { entry -> Int? in
            let name = entry.lastPathComponent
            guard name.hasPrefix("slot-"), name.hasSuffix(".lock"),
                  let index = Int(name.dropFirst(5).dropLast(5)), index >= 0 else { return nil }
            return index
        })
        var activeJobCount = 0
        var availableIndex: Int?
        for index in indices.sorted() {
            let handle = try Self.open(directory.appending(path: "slot-\(index).lock"), create: false)
            let isAvailable = try Self.withHandle(handle) { try Self.tryLock(handle) }
            if isAvailable {
                if availableIndex == nil { availableIndex = index }
            } else {
                activeJobCount += 1
            }
        }
        if let availableIndex { return (activeJobCount, availableIndex) }
        var nextIndex = 0
        while indices.contains(nextIndex) { nextIndex += 1 }
        return (activeJobCount, nextIndex)
    }

    public enum ConfigurationError: Error, LocalizedError {
        case invalidCapacity
        case invalidStoredCapacity(directory: URL)

        public var errorDescription: String? {
            switch self {
            case .invalidCapacity:
                return "The maximum concurrent job count must be positive."
            case .invalidStoredCapacity(let directory):
                return "The pool at \(directory.path(percentEncoded: false)) has an invalid saved capacity. Expected a positive integer."
            }
        }
    }

    private static func open(_ url: URL, create: Bool = true) throws -> FileHandle {
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_RDWR | O_CLOEXEC | (create ? O_CREAT : 0), S_IRUSR | S_IWUSR)
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

    private static func withHandle<Result: Sendable>(
        _ handle: FileHandle,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let result: Swift.Result<Result, any Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        return try withHandle(handle) { try result.get() }
    }

    private static func withHandle<Result>(
        _ handle: FileHandle,
        operation: () throws -> Result
    ) throws -> Result {
        let result: Swift.Result<Result, any Error>
        do { result = .success(try operation()) }
        catch { result = .failure(error) }
        do { try handle.close() }
        catch {
            let operationError: (any Error)?
            switch result {
            case .success: operationError = nil
            case .failure(let error): operationError = error
            }
            throw HostExecutionCleanupFailure(operationError: operationError, cleanupError: error)
        }
        return try result.get()
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

/// A host-lock close failure, with any preceding operation failure preserved.
public struct HostExecutionCleanupFailure: Error, LocalizedError {
    public let operationError: (any Error)?
    public let cleanupError: any Error

    public var errorDescription: String? {
        let original = operationError.map { "Operation failed: \($0). " } ?? ""
        return original + "Closing the host execution lock failed: \(cleanupError)."
    }
}
