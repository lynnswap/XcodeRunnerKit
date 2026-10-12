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

        fileprivate func prepare() throws {
            for location in [workDirectory, compilationCacheDirectory, buildDirectory] {
                try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
                let probe = location.appending(path: ".host-storage-\(UUID().uuidString)")
                try Data().write(to: probe, options: .withoutOverwriting)
                try FileManager.default.removeItem(at: probe)
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
        if let existing = try storage() {
            if let directory, directory.standardizedFileURL.resolvingSymlinksInPath().path != existing.directory.resolvingSymlinksInPath().path {
                throw ConfigurationError.alreadyConfigured(existing.directory)
            }
            try existing.prepare()
            return existing
        }
        return try saveStorageDirectory(directory ?? hostRoot.appending(path: "Storage"))
    }

    // The host commits this active location only after its startup migration succeeds.
    package func saveStorageDirectory(_ directory: URL) throws -> Storage {
        let requested = Storage(directory: directory)
        try requested.prepare()
        let storage = Storage(directory: try requested.directory.resolvingSymlinksInPath().compilerCanonicalURL())
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        try Data(storage.directory.path(percentEncoded: false).utf8).write(to: storageRecord, options: .atomic)
        return storage
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
