import CryptoKit
import Darwin
import Foundation

/// Reuses exclusively leased Simulators across cooperating processes on one Mac.
///
/// A normal test exit returns its cleaned device to the pool without shutting it
/// down. Builds reuse their destination without booting or changing runtime state.
/// Cancelled, interrupted, or abandoned leases are retired before reuse.
/// When attached to an execution pool, all configurations share its saved device limit.
/// Matching devices are reused by most recent return. Clean idle devices follow
/// the execution pool's retention policy, or expire after 20 minutes by default.
/// Abandoned devices are removed regardless of the retention policy.
/// Keep the directory and its lock files in place while clients are running.
public struct SimulatorPool: Sendable {
    public let directory: URL
    var executionPool: HostExecutionPool?
    var now: @Sendable () -> Date = { Date() }

    /// The registry XcodeRunner uses when no execution pool is configured.
    ///
    /// It is the registry of the installed host's pool, so devices created by
    /// earlier versions remain in use.
    public static var defaultDirectory: URL {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(filePath: $0) } ?? .homeDirectory
        let pool = home.appending(path: "Library/Application Support/XcodeRunnerKit/Pool")
        return HostExecutionPool(directory: pool).simulatorPoolDirectory
    }

    public init(directory: URL = Self.defaultDirectory) {
        self.directory = directory.resolvingSymlinksInPath()
        if self.directory == Self.defaultDirectory.resolvingSymlinksInPath() {
            executionPool = HostExecutionPool(directory: self.directory.deletingLastPathComponent())
        }
    }

    /// Deletes idle devices, including abandoned devices. An execution pool also
    /// includes the custom registries previously used by its runners.
    ///
    /// Active leases are skipped. Pass a developer directory to restrict cleanup
    /// to devices registered with that Xcode. Deletion uses the currently selected Xcode.
    public func removeIdleSimulators(developerDirectory: URL? = nil) async throws {
        try await removeIdleSimulators(developerDirectory: developerDirectory, executableURL: URL(filePath: "/usr/bin/xcrun"))
    }

    func removeIdleSimulators(developerDirectory: URL? = nil, executableURL: URL) async throws {
        let selected = developerDirectory?.resolvingSymlinksInPath().path(percentEncoded: false)
        guard try hasRegistries() else { return }
        try await withRegistryLock {
            for entry in try await entries() where selected == nil || entry.key.developerDirectory == selected {
                _ = try await deleteIdle(entry, tool: SimulatorTool(executableURL: executableURL))
            }
        }
    }

    func removeExcessSimulators(executableURL: URL) async throws {
        try await removeExcessSimulators(tool: SimulatorTool(executableURL: executableURL))
    }

    private func removeExcessSimulators(tool: SimulatorTool) async throws {
        guard try hasRegistries() else { return }
        try await withRegistryLock {
            let configuration = try executionPool?.configuration()
            try await removeAbandonedOrExpiredSimulators(
                retention: configuration?.simulatorRetention ?? .idleTimeout(minutes: 20), tool: tool
            )
            if let capacity = configuration?.maximumConcurrentJobs {
                _ = try await removeIdleSimulators(above: capacity, tool: tool)
            }
        }
    }

    func withSimulator(
        action: XcodeBuildAction,
        configuration: SimulatorConfiguration,
        developerDirectory: URL,
        tool: SimulatorTool,
        operation: @Sendable (String, Int32) async -> XcodeBuildOutcome
    ) async -> XcodeBuildOutcome {
        let key = Key(
            developerDirectory: developerDirectory.resolvingSymlinksInPath().path(percentEncoded: false),
            runtimeIdentifier: configuration.runtimeIdentifier,
            deviceTypeIdentifier: configuration.deviceTypeIdentifier
        )
        let lease: Lease
        do { lease = try await acquire(key: key, reusesDevice: configuration.reusesDevice, tool: tool) }
        catch { return .failure(wrapping: error) }
        let runsTests = action == .test || action == .testWithoutBuilding
        var cleanupErrors: [any Error] = []

        var executionTool = tool
        executionTool.inheritedLeaseDescriptor = lease.processHandle.fileDescriptor
        let protectedTool = executionTool
        let execution: Execution
        // Creation finishes even after cancellation so its identifier can be recorded.
        do {
            let identifier = try await Task.detached {
                try await Self.prepare(lease, configuration: configuration, tool: protectedTool)
            }.value
            do {
                try Task.checkCancellation()
                if runsTests { try await protectedTool.boot(identifier) }
                execution = Execution(identifier: identifier, outcome: await operation(identifier, lease.processHandle.fileDescriptor))
            } catch {
                execution = Execution(identifier: identifier, outcome: .failure(wrapping: error))
            }
        } catch {
            execution = Execution(identifier: nil, outcome: .failure(wrapping: error))
        }
        do { try lease.processHandle.close() } catch { cleanupErrors.append(error) }

        // A separate open description waits for inherited holders after ours closes.
        // The parent-only guard prevents another owner from taking this entry meanwhile.
        do {
            let cleanupHandle = try Self.open(Self.processLockURL(for: lease.recordURL))
            do {
                try await Task.detached { try await Self.lock(cleanupHandle) }.value
                var cleanupTool = tool
                cleanupTool.inheritedLeaseDescriptor = cleanupHandle.fileDescriptor
                cleanupErrors += await finish(
                    lease, execution: execution, runsTests: runsTests,
                    reusesDevice: configuration.reusesDevice, tool: cleanupTool
                )
            } catch {
                cleanupErrors.append(Self.cleanupFailure(lease, execution: execution, error: error))
            }
            do { try cleanupHandle.close() } catch { cleanupErrors.append(error) }
        } catch {
            cleanupErrors.append(Self.cleanupFailure(lease, execution: execution, error: error))
        }
        // Failed cleanup keeps ownership so this maintenance pass cannot retry its own retirement.
        let releaseBeforeMaintenance = cleanupErrors.isEmpty
        if releaseBeforeMaintenance {
            do { try lease.handle.close() } catch { cleanupErrors.append(error) }
        }
        do { try await Task.detached { try await removeExcessSimulators(tool: tool) }.value }
        catch { cleanupErrors.append(error) }
        if !releaseBeforeMaintenance {
            do { try lease.handle.close() } catch { cleanupErrors.append(error) }
        }
        return execution.outcome.cancelledIfNeeded().addingCleanupErrors(cleanupErrors)
    }

    private struct Execution: Sendable {
        let identifier: String?
        let outcome: XcodeBuildOutcome
    }

    /// Returns the device to the pool or retires it, reporting each cleanup failure.
    private func finish(
        _ lease: Lease, execution: Execution, runsTests: Bool, reusesDevice: Bool, tool: SimulatorTool
    ) async -> [any Error] {
        let reuse = reusesDevice && execution.identifier != nil && !Task.isCancelled && Self.canReuse(after: execution.outcome)
        do {
            if reuse, let identifier = execution.identifier {
                try await Task.detached {
                    if runsTests { try await tool.prepareForReuse(identifier) }
                    try Self.saveRecord(Record(identifier: identifier, isReady: true, returnedAt: now()), at: lease.recordURL)
                }.value
            } else {
                try await retire(lease, identifier: execution.identifier, tool: tool)
            }
            if reuse, Task.isCancelled {
                try Self.saveRecord(Record(identifier: execution.identifier, isReady: false), at: lease.recordURL)
                try await retire(lease, identifier: execution.identifier, tool: tool)
            }
            return []
        } catch {
            var errors = [Self.cleanupFailure(lease, execution: execution, error: error)]
            if reuse {
                do { try await retire(lease, identifier: execution.identifier, tool: tool) }
                catch { errors.append(Self.cleanupFailure(lease, execution: execution, error: error)) }
            }
            return errors
        }
    }

    private static func cleanupFailure(_ lease: Lease, execution: Execution, error: any Error) -> SimulatorCleanupFailure {
        SimulatorCleanupFailure(
            simulatorIdentifier: execution.identifier ?? lease.record.identifier,
            simulatorName: deviceName(for: lease.recordURL), underlyingError: error
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
        var returnedAt: Date?
    }

    private struct Lease: Sendable {
        let recordURL: URL
        let record: Record
        let handle: FileHandle
        let processHandle: FileHandle
    }

    private struct Entry: Sendable {
        let key: Key
        let recordURL: URL
        let returnedAt: Date
    }

    private func acquire(key: Key, reusesDevice: Bool, tool: SimulatorTool) async throws -> Lease {
        let encodedKey = try JSONEncoder().encode([key.developerDirectory, key.runtimeIdentifier, key.deviceTypeIdentifier])
        let digest = SHA256.hash(data: encodedKey).map { String(format: "%02x", $0) }.joined()
        let keyDirectory = directory.appending(path: digest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let executionPool {
            try FileManager.default.createDirectory(at: executionPool.directory, withIntermediateDirectories: true)
        }
        while true {
            try Task.checkCancellation()
            let lease: Lease? = try await withRegistryLock {
                try registerRegistry()
                let configuration = try executionPool?.configuration()
                try await removeAbandonedOrExpiredSimulators(
                    retention: configuration?.simulatorRetention ?? .idleTimeout(minutes: 20), tool: tool
                )
                let capacity = configuration?.maximumConcurrentJobs
                try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
                let existing: Lease? = try await Self.withKeyLock(keyDirectory) {
                    try JSONEncoder().encode(key).write(to: keyDirectory.appending(path: "configuration.json"), options: .atomic)
                    guard reusesDevice else { return nil }
                    for recordURL in try Self.reuseOrder(in: keyDirectory) {
                        guard let handles = try await Self.tryAcquireHandles(for: recordURL) else { continue }
                        do {
                            if var record = try Self.readRecordIfPresent(recordURL) {
                                record.returnedAt = try Self.returnDate(of: record, at: recordURL)
                                try Self.saveRecord(Record(identifier: record.identifier, isReady: false, returnedAt: record.returnedAt), at: recordURL)
                                return Lease(recordURL: recordURL, record: record, handle: handles.handle, processHandle: handles.processHandle)
                            }
                        } catch { return try await Self.withHandles(handles) { throw error } }
                        try await Self.withHandles(handles) {}
                    }
                    return nil
                }
                if let existing {
                    let remaining: Int?
                    do {
                        if let capacity {
                            remaining = try await removeIdleSimulators(above: capacity, tool: tool)
                        } else {
                            remaining = nil
                        }
                    } catch {
                        return try await Self.withHandles((existing.handle, existing.processHandle)) { throw error }
                    }
                    if let capacity, let remaining, remaining > capacity {
                        return try await Self.withHandles((existing.handle, existing.processHandle)) {
                            try Self.saveRecord(existing.record, at: existing.recordURL)
                            return nil
                        }
                    }
                    return existing
                }
                if let capacity,
                   try await removeIdleSimulators(above: capacity - 1, tool: tool) >= capacity {
                    return nil
                }
                return try await Self.withKeyLock(keyDirectory) {
                    while true {
                        let recordURL = keyDirectory.appending(path: "device-\(UUID().uuidString).json")
                        guard let handles = try await Self.tryAcquireHandles(for: recordURL) else { continue }
                        do {
                            let record = Record(identifier: nil, isReady: false)
                            // Count the reservation before simctl creates a device outside the registry lock.
                            try Self.saveRecord(record, at: recordURL)
                            return Lease(recordURL: recordURL, record: record, handle: handles.handle, processHandle: handles.processHandle)
                        } catch { return try await Self.withHandles(handles) { throw error } }
                    }
                }
            }
            if let lease { return lease }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func entries() async throws -> [Entry] {
        var result: [Entry] = []
        for registry in try registryDirectories() {
            let keys: [URL]
            do { keys = try FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: [.isDirectoryKey]) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            for keyDirectory in keys.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard try keyDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                let found: [Entry] = try await Self.withKeyLock(keyDirectory) {
                    let key: Key
                    do { key = try JSONDecoder().decode(Key.self, from: Data(contentsOf: keyDirectory.appending(path: "configuration.json"))) }
                    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
                    return try Self.recordURLs(in: keyDirectory).compactMap { recordURL in
                        guard let record = try Self.readRecordIfPresent(recordURL) else { return nil }
                        return try Entry(key: key, recordURL: recordURL, returnedAt: Self.returnDate(of: record, at: recordURL))
                    }
                }
                result += found
            }
        }
        return result.sorted {
            if $0.returnedAt != $1.returnedAt { return $0.returnedAt < $1.returnedAt }
            return $0.recordURL.path(percentEncoded: false) < $1.recordURL.path(percentEncoded: false)
        }
    }

    /// Called under the registry coordinator. Both entry locks and a record reread
    /// distinguish an abandoned operation from one whose children still own its device.
    private func removeAbandonedOrExpiredSimulators(
        retention: HostExecutionPool.SimulatorRetention, tool: SimulatorTool
    ) async throws {
        let cutoff: Date?
        switch retention {
        case .forever: cutoff = nil
        case .idleTimeout(let minutes): cutoff = now().addingTimeInterval(-TimeInterval(minutes) * 60)
        }
        for entry in try await entries() {
            _ = try await deleteIdle(entry, tool: tool) { record, returnedAt in
                !record.isReady || cutoff.map { returnedAt <= $0 } == true
            }
        }
    }

    /// Called under the registry coordinator; active entry locks are never waited on.
    private func removeIdleSimulators(above limit: Int, tool: SimulatorTool) async throws -> Int {
        let registered = try await entries()
        var count = registered.count
        for entry in registered where count > limit {
            if try await deleteIdle(entry, tool: tool) { count -= 1 }
        }
        return count
    }

    private func deleteIdle(
        _ entry: Entry, tool: SimulatorTool,
        shouldRemove: @Sendable (Record, Date) -> Bool = { _, _ in true }
    ) async throws -> Bool {
        try Task.checkCancellation()
        return try await Self.withKeyLock(entry.recordURL.deletingLastPathComponent()) {
            guard let handles = try await Self.tryAcquireHandles(for: entry.recordURL) else { return false }
            return try await Self.withHandles(handles) {
                guard let record = try Self.readRecordIfPresent(entry.recordURL) else { return true }
                let returnedAt = try Self.returnDate(of: record, at: entry.recordURL)
                guard returnedAt <= entry.returnedAt, shouldRemove(record, returnedAt) else { return false }
                do {
                    var deletionTool = tool
                    deletionTool.developerDirectory = try await SimulatorTool.selectedDeveloperDirectory(tool.developerDirectory)
                    deletionTool.inheritedLeaseDescriptor = handles.processHandle.fileDescriptor
                    let protectedTool = deletionTool
                    try Self.saveRecord(Record(identifier: record.identifier, isReady: false, returnedAt: returnedAt), at: entry.recordURL)
                    try await Task.detached {
                        try await protectedTool.delete(identifier: record.identifier, name: Self.deviceName(for: entry.recordURL))
                        try Self.removeEntryFiles(for: entry.recordURL)
                    }.value
                    return true
                } catch {
                    throw SimulatorCleanupFailure(
                        simulatorIdentifier: record.identifier, simulatorName: Self.deviceName(for: entry.recordURL),
                        underlyingError: error
                    )
                }
            }
        }
    }

    private func withRegistryLock<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let lock = executionPool.map { $0.directory.appending(path: "simulator-pool.lock") }
            ?? directory.appending(path: "pool.lock")
        let coordinator = try Self.open(lock)
        return try await Self.withHandle(coordinator) {
            try await Self.lock(coordinator)
            return try await operation()
        }
    }

    private var registryReferences: URL? {
        executionPool?.directory.appending(path: "simulator-registries.json")
    }

    private func registeredPaths() throws -> [String] {
        guard let registryReferences else { return [] }
        let data: Data
        do { data = try Data(contentsOf: registryReferences) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try JSONDecoder().decode([String].self, from: data)
    }

    private func registryDirectories() throws -> [URL] {
        let paths = try registeredPaths()
        let defaultDirectory = executionPool?.simulatorPoolDirectory ?? directory
        let registries = [directory, defaultDirectory] + paths.map { URL(filePath: $0) }
        return Set(registries.map(Self.registryPath)).sorted().map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    private func registerRegistry() throws {
        guard let executionPool, let registryReferences else { return }
        let path = Self.registryPath(directory)
        guard path != Self.registryPath(executionPool.simulatorPoolDirectory) else { return }
        var paths = try registeredPaths().map { Self.registryPath(URL(filePath: $0)) }
        guard !paths.contains(path) else { return }
        paths.append(path)
        try JSONEncoder().encode(paths.sorted()).write(to: registryReferences, options: .atomic)
    }

    private static func registryPath(_ directory: URL) -> String {
        var path = directory.resolvingSymlinksInPath().path(percentEncoded: false)
        // Resolving an existing directory can add a trailing slash to the same path.
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func hasRegistries() throws -> Bool {
        var found = false
        for registry in try registryDirectories() {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: registry.path(percentEncoded: false))
                found = true
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
        }
        return found
    }

    private static func withKeyLock<Value: Sendable>(
        _ directory: URL, operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let coordinator = try open(directory.appending(path: "pool.lock"))
        return try await withHandle(coordinator) {
            try await lock(coordinator)
            return try await operation()
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

    private func retire(_ lease: Lease, identifier: String? = nil, tool: SimulatorTool) async throws {
        try await Task.detached {
            if let record = try Self.readRecordIfPresent(lease.recordURL) {
                try await tool.delete(identifier: identifier ?? record.identifier, name: Self.deviceName(for: lease.recordURL))
            }
            try await withRegistryLock {
                try await Self.withKeyLock(lease.recordURL.deletingLastPathComponent()) {
                    try Self.removeEntryFiles(for: lease.recordURL)
                }
            }
        }.value
    }

    private static func removeEntryFiles(for recordURL: URL) throws {
        // The caller holds the key coordinator and both entry locks. Remove the
        // discovery record before allowing either lock path to name a new inode.
        for url in [recordURL, recordURL.deletingPathExtension().appendingPathExtension("lock"), processLockURL(for: recordURL)] {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    private static func canReuse(after outcome: XcodeBuildOutcome) -> Bool {
        let status: XcodeBuildResult.Status?
        switch outcome {
        case .success(let result): status = result.status
        case .failure(let failure): status = failure.result?.status
        }
        if case .exited? = status { return true }
        return false
    }

    private static func recordURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("device-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func returnDate(of record: Record, at url: URL) throws -> Date {
        if let returnedAt = record.returnedAt { return returnedAt }
        // Older registries recorded a successful return by rewriting this file.
        return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
    }

    private static func reuseOrder(in directory: URL) throws -> [URL] {
        let records = try recordURLs(in: directory).compactMap { url -> (URL, Record, Date)? in
            guard let record = try readRecordIfPresent(url) else { return nil }
            return try (url, record, returnDate(of: record, at: url))
        }
        return records.sorted {
            if $0.1.isReady != $1.1.isReady { return $0.1.isReady }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }.map(\.0)
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

extension HostExecutionPool {
    /// The default Simulator registry. Its limit and cleanup include custom
    /// registries used by runners attached to this execution pool.
    public var simulatorPool: SimulatorPool {
        var pool = SimulatorPool(directory: simulatorPoolDirectory)
        pool.executionPool = self
        return pool
    }

    fileprivate var simulatorPoolDirectory: URL { directory.appending(path: "Simulators") }
}
