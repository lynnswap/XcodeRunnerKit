import Foundation

extension HostInstallation {
    private var requestedStorageRecord: URL { hostRoot.appending(path: "requested-storage-directory") }
    private var migrationRecord: URL { hostRoot.appending(path: "storage-migration.json") }

    package func requestedStorageDirectory() throws -> URL? {
        let data: Data
        do { data = try Data(contentsOf: requestedStorageRecord) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else {
            throw StorageMigrationError("Could not read the saved storage folder. Choose and save a folder again.")
        }
        return URL(filePath: path)
    }

    @concurrent package func requestStorageDirectory(_ directory: URL) async throws -> URL {
        let resolved = directory.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw StorageMigrationError("Choose an existing folder for storage.")
        }
        let physical = try resolved.compilerCanonicalURL()
        try await withStorageLock {
            _ = try activeStorageForChange()
            try Data(physical.path(percentEncoded: false).utf8).write(to: requestedStorageRecord, options: .atomic)
        }
        return physical
    }

    // The host calls this only after obtaining ownership of its runners, before starting services.
    @concurrent package func prepareStorageForLaunch() async throws -> Storage {
        try await withStorageLock { try prepareStorageWhileLocked() }
    }

    private func activeStorageForChange() throws -> Storage? {
        do { return try storage() }
        catch {
            throw StorageMigrationError("Could not read the current storage configuration. Restore the original storage-directory record or its read access before changing folders: \(error.localizedDescription)")
        }
    }

    private func prepareStorageWhileLocked() throws -> Storage {
        let active = try activeStorageForChange()
        if let journal = try readMigrationJournal() {
            if active?.directory == journal.target {
                try cleanCommittedMigration(journal)
            } else {
                do { try rollBack(journal) }
                catch {
                    throw StorageMigrationError("The previous storage change was interrupted and could not be restored: \(error.localizedDescription). Runner services remain stopped.")
                }
                throw StorageMigrationError("The previous storage change was interrupted. The original storage and runner settings have been restored. Save a storage folder and restart the host to try again.")
            }
        }
        try Task.checkCancellation()
        let requested = try requestedStorageDirectory()
        if let active, let requested, requested != active.directory {
            let migrated = try migrateStorage(from: active, to: requested)
            try validateHostedWorkDirectories(storage: migrated)
            return migrated
        }
        let prepared = try prepareStorageDirectory(at: active == nil ? requested : nil, creatingParent: requested == nil)
        try validateHostedWorkDirectories(storage: prepared)
        return prepared
    }

    private struct RegistrationBackup: Codable {
        let file: URL
        let data: Data
    }

    private struct MigrationJournal: Codable {
        let source: URL
        let target: URL
        let staging: URL
        let token: String
        let registrations: [RegistrationBackup]
        var directoryNames: [String] { ["Work", "CompilationCache", "Build"] }
        var ownershipName: String { ".xcode-runner-migration-\(token)" }
    }

    private func readMigrationJournal() throws -> MigrationJournal? {
        let data: Data
        do { data = try Data(contentsOf: migrationRecord) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try JSONDecoder().decode(MigrationJournal.self, from: data)
    }

    private func migrateStorage(from source: Storage, to directory: URL) throws -> Storage {
        let manager = FileManager.default
        try source.requireAvailableParent()
        let target = Storage(directory: try directory.resolvingSymlinksInPath().compilerCanonicalURL())
        let sourceDirectories = [source.workDirectory, source.compilationCacheDirectory, source.buildDirectory]
        let names = ["Work", "CompilationCache", "Build"]
        for name in names {
            let destination = target.directory.appending(path: name)
            if try migrationItemExists(at: destination) {
                throw StorageMigrationError("The chosen folder already contains \(name). Choose a different folder so existing files are preserved.")
            }
        }
        let registrations = try hostedRegistrationBackups(storage: source, changingStorage: true)
        let physicalSources = try sourceDirectories.map { try copySource(at: $0)?.directory }
        let runnerWorkCopies = try registrations.compactMap { registration -> (name: String, source: URL)? in
            let name = registration.file.deletingLastPathComponent().lastPathComponent
            let work = source.workDirectory.appending(path: name)
            guard let source = try copySource(at: work), source.isSymbolicLink else { return nil }
            return (name, source.directory)
        }
        for copiedDirectory in physicalSources.compactMap({ $0 }) + runnerWorkCopies.map({ $0.source }) {
            var relationship = FileManager.URLRelationship.other
            try manager.getRelationship(
                &relationship, ofDirectoryAt: copiedDirectory, toItemAt: target.directory
            )
            guard relationship == .other else {
                throw StorageMigrationError("Choose a storage folder outside the work, cache, and build folders being copied.")
            }
        }
        let token = UUID().uuidString
        let journal = MigrationJournal(
            source: source.directory, target: target.directory,
            staging: target.directory.appending(path: ".xcode-runner-migration-\(token)"),
            token: token, registrations: registrations
        )
        try JSONEncoder().encode(journal).write(to: migrationRecord, options: .atomic)
        var didCommit = false
        do {
            try manager.createDirectory(at: journal.staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (name, physical) in zip(names, physicalSources) {
                try Task.checkCancellation()
                let staged = journal.staging.appending(path: name)
                if let physical {
                    try manager.copyItem(at: physical, to: staged)
                    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path(percentEncoded: false))
                    if name == "Work" {
                        for work in runnerWorkCopies {
                            let copiedWork = staged.appending(path: work.name)
                            try manager.removeItem(at: copiedWork)
                            try manager.copyItem(at: work.source, to: copiedWork)
                        }
                    }
                } else {
                    try manager.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                try Data(token.utf8).write(to: staged.appending(path: journal.ownershipName), options: .withoutOverwriting)
                try manager.moveItem(at: staged, to: target.directory.appending(path: name))
            }
            let workDirectory = try target.workDirectory.compilerCanonicalURL()
            for registration in registrations {
                try Task.checkCancellation()
                var object = try registrationObject(registration.data)
                let name = registration.file.deletingLastPathComponent().lastPathComponent
                object["workFolder"] = workDirectory.appending(path: name).path(percentEncoded: false)
                var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                if registration.data.starts(with: [0xEF, 0xBB, 0xBF]) { data = Data([0xEF, 0xBB, 0xBF]) + data }
                try data.write(to: registration.file, options: .atomic)
            }
            try manager.removeItem(at: journal.staging)
            try Task.checkCancellation()
            let committed: Storage
            do { committed = try commitStorageDirectory(target.directory, creatingParent: false) }
            catch {
                // An atomic write can report failure after replacement. Read back before restoring runners.
                let saved: Storage?
                do { saved = try storage() }
                catch {
                    throw StorageCommitStateError("Could not confirm whether the storage change was saved: \(error.localizedDescription). Runner services remain stopped.")
                }
                if saved?.directory == target.directory { committed = target }
                else if saved?.directory == source.directory { throw error }
                else {
                    throw StorageCommitStateError("The saved storage folder changed during migration. Runner services remain stopped.")
                }
            }
            didCommit = true
            // Commit is complete. Cleanup may be retried on the next launch without reverting active storage.
            try cleanCommittedMigration(journal)
            return committed
        } catch let error as StorageCommitStateError {
            throw error
        } catch {
            if didCommit {
                throw StorageMigrationError("The new storage folder was saved, but migration cleanup failed: \(error.localizedDescription). Restart the host to finish cleanup before runner services start.")
            }
            do { try rollBack(journal) }
            catch let rollbackError {
                throw StorageMigrationError("Could not change the storage folder: \(error.localizedDescription). Restoring the original settings also failed: \(rollbackError.localizedDescription). Runner services remain stopped.")
            }
            throw StorageMigrationError("Could not change the storage folder: \(error.localizedDescription). The original storage and runner settings have been preserved.")
        }
    }

    private func copySource(at location: URL) throws -> (directory: URL, isSymbolicLink: Bool)? {
        let values: URLResourceValues
        do { values = try location.resourceValues(forKeys: [.isSymbolicLinkKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let physical = location.resolvingSymlinksInPath()
        guard try physical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw StorageMigrationError("A work, cache, or build folder could not be accessed. Restore access to the original folder before changing storage.")
        }
        return (try physical.compilerCanonicalURL(), values.isSymbolicLink == true)
    }

    private func registrationObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StorageMigrationError("A runner registration could not be read.")
        }
        return object
    }

    private func hostedRegistrationBackups(storage: Storage, changingStorage: Bool = false) throws -> [RegistrationBackup] {
        let manager = FileManager.default
        let directories: [URL]
        do {
            directories = try manager.contentsOfDirectory(at: runnersRoot, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        var backups: [RegistrationBackup] = []
        for directory in directories where try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            let hosted = try migrationItemExists(at: directory.appending(path: ".xcode-runner-host"))
            let individual = try migrationItemExists(at: directory.appending(path: ".service"))
            guard hosted || individual else { continue }
            if individual && !changingStorage { continue }
            let file = directory.appending(path: ".runner")
            guard try migrationItemExists(at: file) else { continue }
            let data = try Data(contentsOf: file)
            let object = try registrationObject(data)
            if individual {
                if hosted {
                    throw StorageMigrationError("\(directory.lastPathComponent) still has an individual runner service. Remove that service before changing host storage.")
                }
                if let path = object["workFolder"] as? String, path.hasPrefix("/") {
                    let managed = normalizedPathComponents(of: storage.workDirectory)
                    let individual = normalizedPathComponents(of: URL(filePath: path))
                    if individual.starts(with: managed) {
                        throw StorageMigrationError("An individual runner service uses the current storage folder. Stop and remove that service before changing host storage.")
                    }
                }
                continue
            }
            guard let path = object["workFolder"] as? String, path.hasPrefix("/") else {
                throw StorageMigrationError("\(directory.lastPathComponent) uses a different work folder from the host. Correct its registration before starting runner services.")
            }
            let expected = storage.workDirectory.appending(path: directory.lastPathComponent)
                .standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            let registered = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            guard expected == registered else {
                throw StorageMigrationError("\(directory.lastPathComponent) uses a different work folder from the host. Correct its registration before starting runner services.")
            }
            backups.append(RegistrationBackup(file: file, data: data))
        }
        return backups
    }

    private func normalizedPathComponents(of url: URL) -> [String] {
        // Resolve existing prefixes before appending a missing work-folder suffix.
        url.standardizedFileURL.pathComponents.dropFirst().reduce(URL(filePath: "/")) {
            $0.appending(path: $1).resolvingSymlinksInPath()
        }.pathComponents
    }

    private func validateHostedWorkDirectories(storage: Storage) throws {
        _ = try hostedRegistrationBackups(storage: storage)
    }

    private func rollBack(_ journal: MigrationJournal) throws {
        var failures: [String] = []
        for registration in journal.registrations {
            do {
                if try Data(contentsOf: registration.file) != registration.data {
                    try registration.data.write(to: registration.file, options: .atomic)
                }
            }
            catch { failures.append(error.localizedDescription) }
        }
        for name in journal.directoryNames {
            let directory = journal.target.appending(path: name)
            do {
                guard try migrationItemExists(at: directory) else { continue }
                let token = try String(contentsOf: directory.appending(path: journal.ownershipName), encoding: .utf8)
                guard token == journal.token else {
                    throw StorageMigrationError("The destination \(name) folder could not be identified as this host's copy.")
                }
                try removeOwnedCopy(at: directory)
            } catch { failures.append(error.localizedDescription) }
        }
        do {
            if try migrationItemExists(at: journal.staging) { try removeOwnedCopy(at: journal.staging) }
        } catch { failures.append(error.localizedDescription) }
        do { try Storage(directory: journal.target).requireAvailableParent() }
        catch { failures.append(error.localizedDescription) }
        guard failures.isEmpty else { throw StorageMigrationError(failures.joined(separator: " ")) }
        try FileManager.default.removeItem(at: migrationRecord)
    }

    private func migrationItemExists(at location: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: location.path(percentEncoded: false))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private func removeOwnedCopy(at directory: URL) throws {
        let manager = FileManager.default
        func makeDirectoriesRemovable(at location: URL) throws {
            let values = try location.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink == false, values.isDirectory == true else { return }
            let path = location.path(percentEncoded: false)
            guard let permissions = try manager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber else {
                throw StorageMigrationError("A copied folder's permissions could not be read for cleanup.")
            }
            try manager.setAttributes([.posixPermissions: permissions.intValue | 0o300], ofItemAtPath: path)
            for child in try manager.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                try makeDirectoriesRemovable(at: child)
            }
        }
        try makeDirectoriesRemovable(at: directory)
        try manager.removeItem(at: directory)
    }

    private func cleanCommittedMigration(_ journal: MigrationJournal) throws {
        for name in journal.directoryNames {
            let token = journal.target.appending(path: name).appending(path: journal.ownershipName)
            do { try FileManager.default.removeItem(at: token) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
        if try migrationItemExists(at: journal.staging) {
            try FileManager.default.removeItem(at: journal.staging)
        }
        try Storage(directory: journal.target).requireAvailableParent()
        try FileManager.default.removeItem(at: migrationRecord)
    }
}

private struct StorageMigrationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct StorageCommitStateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
