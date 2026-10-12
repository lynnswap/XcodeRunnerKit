import Darwin
import Foundation

/// Shares an execution limit between cooperating processes on one Mac.
///
/// Repository runners share one local directory. Its saved capacity limits new
/// operations; a caller's capacity initializes an empty pool.
/// Do not remove the directory or its lock files while jobs are running.
public struct HostExecutionPool: Sendable {
    /// The shared directory, with symlinks resolved when the pool is created.
    public let directory: URL
    private let initialCapacity: Int

    /// Creates a pool with a capacity to use when its first slot acquisition initializes the directory.
    ///
    /// Creating the value does not configure the directory.
    public init(directory: URL, initialCapacity: Int) throws {
        guard initialCapacity > 0 else {
            throw ConfigurationError.invalidCapacity
        }
        self.directory = directory.resolvingSymlinksInPath()
        self.initialCapacity = initialCapacity
    }

    /// The admission order for waiting operations. Running operations are never preempted.
    public enum Priority: String, Sendable, CaseIterable, Codable {
        case high
        case normal
        case low

        fileprivate var rank: Int {
            switch self {
            case .high: 2
            case .normal: 1
            case .low: 0
            }
        }
    }

    /// The number of waiting operations at each priority.
    public struct WaitingJobCounts: Sendable, Equatable, Codable {
        public let high: Int
        public let normal: Int
        public let low: Int

        public var total: Int { high + normal + low }

        public subscript(_ priority: Priority) -> Int {
            switch priority {
            case .high: high
            case .normal: normal
            case .low: low
            }
        }
    }

    /// The configured limit, slots observed in use, and waiting operation counts.
    public struct Status: Sendable, Equatable, Codable {
        public let maximumConcurrentJobs: Int
        public let activeJobCount: Int
        public let waitingJobCounts: WaitingJobCounts
    }

    /// Reads the pool without initializing an unconfigured directory.
    ///
    /// Running operations can finish while this snapshot is being read.
    public func status() async throws -> Status? {
        let coordinator: FileHandle
        do {
            coordinator = try Self.open(directory.appending(path: "pool.lock"), create: false)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
        return try await Self.withHandle(coordinator) {
            try await Self.lock(coordinator)
            guard let capacity = try savedCapacity() else { return nil }
            let waiters = try inspectWaiters()
            return try Status(
                maximumConcurrentJobs: capacity, activeJobCount: inspectSlots().activeJobCount,
                waitingJobCounts: WaitingJobCounts(
                    high: waiters.count(where: { $0.priority == .high }),
                    normal: waiters.count(where: { $0.priority == .normal }),
                    low: waiters.count(where: { $0.priority == .low })
                )
            )
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
        let coordinator = try Self.open(directory.appending(path: "pool.lock"))
        try await Self.withHandle(coordinator) {
            try await Self.lock(coordinator)
            try saveCapacity(capacity)
        }
    }

    /// Holds a host slot until the operation, including its cleanup, finishes.
    ///
    /// Waiting is cancellable. Lock or configuration failures never bypass
    /// the limit. Processes use kernel locks, so no stale PID files are needed.
    /// Higher priorities start first; equal priorities start in their local
    /// registration order. Continuous higher-priority work can postpone lower priorities.
    public func withSlot<Result: Sendable>(
        priority: Priority = .normal,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (waiter, ownership) = try await registerWaiter(priority: priority)
        return try await Self.withHandle(ownership) {
            let outcome: Swift.Result<Result, any Error>
            do { outcome = .success(try await runWaiting(waiter, operation: operation)) }
            catch { outcome = .failure(error) }
            do { try Self.removeWaiter(waiter.url) }
            catch {
                throw HostExecutionCleanupFailure(operationError: outcome.failure, cleanupError: error)
            }
            return try outcome.get()
        }
    }

    private func runWaiting<Result: Sendable>(
        _ waiter: Waiter, operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        while true {
            try Task.checkCancellation()
            let coordinator = try Self.open(directory.appending(path: "pool.lock"))
            let slot: FileHandle? = try await Self.withHandle(coordinator) {
                try await Self.lock(coordinator)
                guard let capacity = try savedCapacity() else {
                    throw ConfigurationError.invalidStoredCapacity(directory: directory)
                }
                let slots = try inspectSlots()
                guard slots.activeJobCount < capacity else { return nil }
                let waiters = try inspectWaiters()
                guard waiters.first?.url.lastPathComponent == waiter.url.lastPathComponent else { return nil }
                let handle = try Self.open(directory.appending(path: "slot-\(slots.availableIndex).lock"))
                do {
                    if try Self.tryLock(handle) {
                        try Self.removeWaiter(waiter.url)
                        return handle
                    }
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

    private struct Waiter: Sendable {
        let sequence: Int
        let priority: Priority
        let url: URL
    }

    private func registerWaiter(priority: Priority) async throws -> (Waiter, FileHandle) {
        let coordinator = try Self.open(directory.appending(path: "pool.lock"))
        return try await Self.withHandle(coordinator) {
            try await Self.lock(coordinator)
            if try savedCapacity() == nil { try saveCapacity(initialCapacity) }
            let previousSequence = try inspectWaiters().map(\.sequence).max() ?? -1
            let (sequence, overflow) = previousSequence.addingReportingOverflow(1)
            guard !overflow else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EOVERFLOW)) }
            let url = directory.appending(path: "waiter-\(sequence)-\(priority.rawValue)-\(UUID().uuidString).lock")
            let handle = try Self.open(url)
            do {
                guard try Self.tryLock(handle) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
                }
                return (Waiter(sequence: sequence, priority: priority, url: url), handle)
            } catch {
                return try Self.withHandle(handle) { throw error }
            }
        }
    }

    private func inspectWaiters() throws -> [Waiter] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var waiters: [Waiter] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("waiter-"), name.hasSuffix(".lock") else { continue }
            let parts = name.dropFirst(7).dropLast(5).split(separator: "-", maxSplits: 2)
            guard parts.count == 3, let sequence = Int(parts[0]), sequence >= 0,
                  let priority = Priority(rawValue: String(parts[1])), UUID(uuidString: String(parts[2])) != nil else {
                throw ConfigurationError.invalidStoredWaiter(entry)
            }
            let handle: FileHandle
            do { handle = try Self.open(entry, create: false) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                // Cancellation can remove a waiting record while its directory snapshot is being inspected.
                continue
            }
            try Self.withHandle(handle) {
                if try Self.tryLock(handle) {
                    try Self.removeWaiter(entry)
                } else {
                    waiters.append(Waiter(sequence: sequence, priority: priority, url: entry))
                }
            }
        }
        return waiters.sorted {
            if $0.priority != $1.priority { return $0.priority.rank > $1.priority.rank }
            return $0.sequence < $1.sequence
        }
    }

    private static func removeWaiter(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    private func savedCapacity() throws -> Int? {
        let stored: Data
        do {
            stored = try Data(contentsOf: directory.appending(path: "capacity"))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
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
        case invalidStoredWaiter(URL)

        public var errorDescription: String? {
            switch self {
            case .invalidCapacity:
                return "The maximum concurrent job count must be positive."
            case .invalidStoredCapacity(let directory):
                return "The pool at \(directory.path(percentEncoded: false)) has an invalid saved capacity. Expected a positive integer."
            case .invalidStoredWaiter(let url):
                return "The waiting record at \(url.path(percentEncoded: false)) has an invalid sequence or priority."
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

private extension Swift.Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
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
