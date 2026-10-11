import Darwin
import Foundation

/// Shares an execution limit between cooperating processes on one Mac.
///
/// All repository runners must use the same local directory and capacity.
/// Do not remove the directory or its lock files while jobs are running.
public struct HostExecutionPool: Sendable {
    public let directory: URL
    public let maximumConcurrentJobs: Int

    public init(directory: URL, maximumConcurrentJobs: Int) throws {
        guard maximumConcurrentJobs > 0 else {
            throw ConfigurationError.invalidCapacity
        }
        self.directory = directory
        self.maximumConcurrentJobs = maximumConcurrentJobs
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
        let configuration = try Self.open(directory.appending(path: "capacity.lock"))
        try await Self.withHandle(configuration) {
            try await Self.lock(configuration)
            let stored = try configuration.readToEnd() ?? Data()
            if stored.isEmpty {
                try configuration.write(contentsOf: Data(String(maximumConcurrentJobs).utf8))
                try configuration.synchronize()
            } else if String(data: stored, encoding: .utf8) != String(maximumConcurrentJobs) {
                throw ConfigurationError.capacityMismatch(directory: directory, requested: maximumConcurrentJobs)
            }
        }

        while true {
            try Task.checkCancellation()
            for index in 0..<maximumConcurrentJobs {
                let handle = try Self.open(directory.appending(path: "slot-\(index).lock"))
                let locked: Bool
                do {
                    locked = try Self.tryLock(handle)
                } catch {
                    return try await Self.withHandle(handle) { throw error }
                }
                if locked {
                    return try await Self.withHandle(handle) {
                        try Task.checkCancellation()
                        return try await operation()
                    }
                }
                try handle.close()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public enum ConfigurationError: Error, LocalizedError {
        case invalidCapacity
        case capacityMismatch(directory: URL, requested: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidCapacity:
                return "The maximum concurrent job count must be positive."
            case .capacityMismatch(let directory, let requested):
                return "The pool at \(directory.path(percentEncoded: false)) has a different capacity than \(requested). Stop all jobs before reconfiguring the pool."
            }
        }
    }

    private static func open(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
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
