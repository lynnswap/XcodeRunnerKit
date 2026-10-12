import Darwin
import Foundation

package struct HostInstallation: Sendable {
    package let homeDirectory: URL

    package static var defaultHomeDirectory: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(filePath: $0) } ?? .homeDirectory
    }

    package init(homeDirectory: URL = Self.defaultHomeDirectory) {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    package var hostRoot: URL { homeDirectory.appending(path: "Library/Application Support/XcodeRunnerKit") }
    package var runnersRoot: URL { homeDirectory.appending(path: "Library/XcodeRunnerKit/runners") }
    package var toolsDirectory: URL { hostRoot.appending(path: "bin") }
    package var poolDirectory: URL { hostRoot.appending(path: "Pool") }
    package var logsDirectory: URL { hostRoot.appending(path: "logs/runners") }
    package var applicationsDirectory: URL { homeDirectory.appending(path: "Applications") }
    private var storageRecord: URL { hostRoot.appending(path: "storage-directory") }

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

        package func createBuildDirectory() throws { try createManagedDirectory(buildDirectory) }
        package func createCompilationCacheDirectory() throws { try createManagedDirectory(compilationCacheDirectory) }

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
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let lock = hostRoot.appending(path: "storage.lock")
        let descriptor = open(lock.path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        let lockingDescriptor: Int32
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
            lockingDescriptor = inherited
        } else {
            lockingDescriptor = descriptor
        }
        while flock(lockingDescriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        return try operation()
    }

    package func environment(for storage: Storage) -> [String: String] {
        [
            "XCODE_RUNNER_HOST_STORAGE_DIRECTORY": storage.directory.path(percentEncoded: false),
            "XCODE_RUNNER_HOST_ROOT": hostRoot.path(percentEncoded: false),
        ]
    }

    package static func hostedConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (storage: Storage, poolDirectory: URL)? {
        let directory = environment["XCODE_RUNNER_HOST_STORAGE_DIRECTORY"]
        let root = environment["XCODE_RUNNER_HOST_ROOT"]
        guard directory != nil || root != nil else { return nil }
        guard let directory, let root, !directory.isEmpty, !root.isEmpty else {
            throw ConfigurationError.incompleteHostEnvironment
        }
        return (Storage(directory: URL(filePath: directory)), URL(filePath: root).appending(path: "Pool"))
    }

    package enum ConfigurationError: LocalizedError {
        case invalidStorageRecord(URL)
        case alreadyConfigured(URL)
        case incompleteHostEnvironment

        package var errorDescription: String? {
            switch self {
            case .invalidStorageRecord(let url): "Invalid host storage configuration at \(url.path(percentEncoded: false))."
            case .alreadyConfigured(let url): "Host storage is already configured at \(url.path(percentEncoded: false)). Change existing storage through the host settings."
            case .incompleteHostEnvironment: "The installed host must supply both its active storage directory and host root."
            }
        }
    }
}
