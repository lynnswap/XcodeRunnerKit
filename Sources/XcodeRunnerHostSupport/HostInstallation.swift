import Darwin
import Foundation

extension URL {
    /// The physical path the compiler sees. Storage records keep this form so that
    /// compilation cache prefix mappings match paths under the job-data folder.
    func compilerCanonicalURL() throws -> URL {
        // resolvingSymlinksInPath removes /private, unlike compiler filesystem paths.
        guard let path = try resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: self])
        }
        return URL(filePath: path)
    }
}

package struct HostInstallation: Sendable {
    package let homeDirectory: URL

    package static var defaultHomeDirectory: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(filePath: $0) } ?? .homeDirectory
    }

    package init(homeDirectory: URL = Self.defaultHomeDirectory) {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The limit a host's pool starts with until its settings change it.
    package static let defaultMaximumConcurrentJobs = 4

    package var hostRoot: URL { homeDirectory.appending(path: "Library/Application Support/XcodeRunnerKit") }
    package var runnersRoot: URL { homeDirectory.appending(path: "Library/XcodeRunnerKit/runners") }
    package var toolsDirectory: URL { hostRoot.appending(path: "bin") }
    package var poolDirectory: URL { Self.poolDirectory(hostRoot: hostRoot) }
    package var logsDirectory: URL { hostRoot.appending(path: "logs/runners") }
    package var applicationsDirectory: URL { homeDirectory.appending(path: "Applications") }
    private var storageRecord: URL { hostRoot.appending(path: "storage-directory") }
    private var buildServiceRecord: URL { hostRoot.appending(path: "build-service-path") }

    package func buildServiceExecutableURL() throws -> URL? {
        try Self.buildServiceExecutableURL(hostRoot: hostRoot)
    }

    private static func buildServiceExecutableURL(hostRoot: URL) throws -> URL? {
        let record = hostRoot.appending(path: "build-service-path")
        let data: Data
        do { data = try Data(contentsOf: record) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let path = String(data: data, encoding: .utf8), !path.isEmpty, path.hasPrefix("/") else {
            throw ConfigurationError.invalidBuildServiceRecord(record)
        }
        return URL(filePath: path)
    }

    @discardableResult
    package func saveBuildServiceExecutableURL(_ url: URL?) throws -> URL? {
        guard let url else {
            do { try FileManager.default.removeItem(at: buildServiceRecord) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            return nil
        }
        let executable = url.standardizedFileURL
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        try Data(executable.path(percentEncoded: false).utf8).write(to: buildServiceRecord, options: .atomic)
        return executable
    }

    package struct Storage: Sendable {
        package let directory: URL

        package init(directory: URL) {
            self.directory = directory
        }

        package var workDirectory: URL { directory.appending(path: "Work") }
        package var compilationCacheDirectory: URL { directory.appending(path: "CompilationCache") }
        package var buildDirectory: URL { directory.appending(path: "Build") }

        fileprivate func prepare(creatingParent: Bool) throws {
            if creatingParent {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
            }
            try requireAvailableParent()
            for location in [workDirectory, compilationCacheDirectory, buildDirectory] {
                try createManagedDirectory(location)
                let probe = location.appending(path: ".host-storage-\(UUID().uuidString)")
                try Data().write(to: probe, options: .withoutOverwriting)
                try FileManager.default.removeItem(at: probe)
            }
        }

        package func requireAvailableParent() throws {
            guard try directory.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR), userInfo: [NSURLErrorKey: directory])
            }
        }

        private func createManagedDirectory(_ location: URL) throws {
            if mkdir(location.path(percentEncoded: false), 0o700) != 0, errno != EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSURLErrorKey: location])
            }
        }
    }

    package func storage() throws -> Storage? {
        let data: Data
        do { data = try Data(contentsOf: storageRecord) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let path = String(data: data, encoding: .utf8), !path.isEmpty, path.hasPrefix("/") else {
            throw ConfigurationError.invalidStorageRecord(storageRecord)
        }
        return Storage(directory: URL(filePath: path))
    }

    package func initializeStorage(at directory: URL? = nil) throws -> Storage {
        try withStorageLock { try prepareStorageDirectory(at: directory, creatingParent: true) }
    }

    // Call while holding storage.lock, including throughout startup migration.
    package func prepareStorageDirectory(at directory: URL?, creatingParent: Bool) throws -> Storage {
        if let existing = try storage() {
            if let directory, directory.standardizedFileURL.resolvingSymlinksInPath().path != existing.directory.resolvingSymlinksInPath().path {
                throw ConfigurationError.alreadyConfigured(existing.directory)
            }
            try existing.prepare(creatingParent: false)
            return existing
        }
        return try commitStorageDirectory(directory ?? hostRoot.appending(path: "Storage"), creatingParent: creatingParent)
    }

    // The host commits this active location only after its startup migration succeeds.
    package func saveStorageDirectory(_ directory: URL) throws -> Storage {
        try withStorageLock { try commitStorageDirectory(directory, creatingParent: false) }
    }

    package func commitStorageDirectory(_ directory: URL, creatingParent: Bool) throws -> Storage {
        let requested = Storage(directory: directory)
        try requested.prepare(creatingParent: creatingParent)
        let storage = Storage(directory: try requested.directory.resolvingSymlinksInPath().compilerCanonicalURL())
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        try Data(storage.directory.path(percentEncoded: false).utf8).write(to: storageRecord, options: .atomic)
        return storage
    }

    package func withStorageLock<Result>(_ operation: () throws -> Result) throws -> Result {
        let descriptors = try storageLockDescriptors()
        defer { close(descriptors.owned) }
        while flock(descriptors.locking, LOCK_EX) != 0 {
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        return try operation()
    }

    @concurrent package func withStorageLock<Result: Sendable>(
        _ operation: @Sendable () throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let descriptors = try storageLockDescriptors()
        defer { close(descriptors.owned) }
        while flock(descriptors.locking, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        return try operation()
    }

    private func storageLockDescriptors() throws -> (owned: Int32, locking: Int32) {
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let lock = hostRoot.appending(path: "storage.lock")
        let descriptor = open(lock.path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do {
            if let inherited = ProcessInfo.processInfo.environment["XCODE_RUNNER_STORAGE_LOCK_DESCRIPTOR"] {
                // The installer holds this open file description across nested configure and opt-in calls.
                guard let inherited = Int32(inherited) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
                var ownStatus = stat()
                var inheritedStatus = stat()
                guard fstat(descriptor, &ownStatus) == 0, fstat(inherited, &inheritedStatus) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard ownStatus.st_dev == inheritedStatus.st_dev, ownStatus.st_ino == inheritedStatus.st_ino else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
                }
                return (descriptor, inherited)
            }
            return (descriptor, descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    package func environment(for storage: Storage) -> [String: String] {
        [
            "XCODE_RUNNER_HOST_STORAGE_DIRECTORY": storage.directory.path(percentEncoded: false),
            "XCODE_RUNNER_HOST_ROOT": hostRoot.path(percentEncoded: false),
        ]
    }

    package static func hostedConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (storage: Storage, poolDirectory: URL, buildServiceExecutableURL: URL?)? {
        guard let hosted = try hostedLocations(environment) else { return nil }
        return (
            Storage(directory: hosted.storageDirectory),
            poolDirectory(hostRoot: hosted.hostRoot),
            try buildServiceExecutableURL(hostRoot: hosted.hostRoot)
        )
    }

    /// The pool a hosted job uses. Unlike hostedConfiguration, this reads no saved host settings.
    package static func hostedPoolDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL? {
        try hostedLocations(environment).map { poolDirectory(hostRoot: $0.hostRoot) }
    }

    private static func hostedLocations(_ environment: [String: String]) throws -> (storageDirectory: URL, hostRoot: URL)? {
        let directory = environment["XCODE_RUNNER_HOST_STORAGE_DIRECTORY"]
        let root = environment["XCODE_RUNNER_HOST_ROOT"]
        guard directory != nil || root != nil else { return nil }
        guard let directory, let root, !directory.isEmpty, !root.isEmpty else {
            throw ConfigurationError.incompleteHostEnvironment
        }
        return (URL(filePath: directory), URL(filePath: root))
    }

    private static func poolDirectory(hostRoot: URL) -> URL { hostRoot.appending(path: "Pool") }

    package enum ConfigurationError: LocalizedError {
        case invalidStorageRecord(URL)
        case invalidBuildServiceRecord(URL)
        case alreadyConfigured(URL)
        case incompleteHostEnvironment

        package var errorDescription: String? {
            switch self {
            case .invalidStorageRecord(let url): "Invalid host storage configuration at \(url.path(percentEncoded: false))."
            case .invalidBuildServiceRecord(let url): "Invalid host build service configuration at \(url.path(percentEncoded: false))."
            case .alreadyConfigured(let url): "Host storage is already configured at \(url.path(percentEncoded: false)). Change existing storage through the host settings."
            case .incompleteHostEnvironment: "The installed host must supply both its active storage directory and host root."
            }
        }
    }
}
