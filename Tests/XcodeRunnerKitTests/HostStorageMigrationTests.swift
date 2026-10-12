import Foundation
import Testing
@testable import XcodeRunnerKit

struct HostStorageMigrationTests {
    private func fixture() throws -> (root: URL, installation: HostInstallation, storage: HostInstallation.Storage) {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        return (root, installation, try installation.initializeStorage(at: root.appending(path: "First")))
    }

    private func runner(_ name: String, installation: HostInstallation, storage: HostInstallation.Storage, hosted: Bool = true) throws -> URL {
        let directory = installation.runnersRoot.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if hosted { try Data().write(to: directory.appending(path: ".xcode-runner-host")) }
        let object: [String: Any] = [
            "agentName": name, "agentId": 12, "serverUrl": "https://github.com/example/repository",
            "workFolder": storage.workDirectory.appending(path: name).path(percentEncoded: false),
            "unknownSetting": ["retained": true],
        ]
        try (Data([0xEF, 0xBB, 0xBF]) + JSONSerialization.data(withJSONObject: object)).write(to: directory.appending(path: ".runner"))
        try Data("credential bytes".utf8).write(to: directory.appending(path: ".credentials"))
        try FileManager.default.createDirectory(at: storage.workDirectory.appending(path: name), withIntermediateDirectories: true)
        return directory
    }

    private func choose(_ directory: URL, installation: HostInstallation) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await installation.requestStorageDirectory(directory)
    }

    @Test func unchangedStoragePreparesMissingManagedDirectoriesBeforeRunnerStartup() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: source.directory)
        let prepared = try await installation.prepareStorageForLaunch()
        #expect(prepared.directory == source.directory)
        for directory in [prepared.workDirectory, prepared.compilationCacheDirectory, prepared.buildDirectory] {
            #expect(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }
        #expect(try installation.storage()?.directory == source.directory)
    }

    @Test func removedManagedWorkFolderCanBeRecreatedByRunnerAfterLaunchOrRelocation() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try runner("runner-one", installation: installation, storage: source)
        let work = source.workDirectory.appending(path: "runner-one")
        let metadata = directory.appending(path: ".runner")
        let original = try Data(contentsOf: metadata)
        try FileManager.default.removeItem(at: work)
        #expect(try await installation.prepareStorageForLaunch().directory == source.directory)
        #expect(try Data(contentsOf: metadata) == original)
        #expect(!FileManager.default.fileExists(atPath: work.path(percentEncoded: false)))
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        let migrated = try await installation.prepareStorageForLaunch()
        #expect(migrated.directory == target)
        let registration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        let newWork = migrated.workDirectory.appending(path: "runner-one")
        #expect(registration["workFolder"] as? String == newWork.path(percentEncoded: false))
        try FileManager.default.createDirectory(at: newWork, withIntermediateDirectories: true)
        #expect(try newWork.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test func savedSelectionDoesNotChangeRunningStorageAndCopiesOnNextLaunch() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try runner("runner-one", installation: installation, storage: source)
        let original = try Data(contentsOf: registration.appending(path: ".runner"))
        let credentials = try Data(contentsOf: registration.appending(path: ".credentials"))
        for directory in [source.workDirectory, source.compilationCacheDirectory, source.buildDirectory] {
            try Data("retained job data".utf8).write(to: directory.appending(path: "data"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.compilationCacheDirectory.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.compilationCacheDirectory.path(percentEncoded: false)) }
        let environment = installation.environment(for: source)
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        try Data("unrelated files".utf8).write(to: target.appending(path: "unrelated"))
        #expect(try installation.storage()?.directory == source.directory)
        #expect(try Data(contentsOf: registration.appending(path: ".runner")) == original)
        #expect(try HostInstallation.hostedConfiguration(environment: environment)?.storage.directory == source.directory)
        let migrated = try await installation.prepareStorageForLaunch()
        #expect(migrated.directory == target)
        #expect(try installation.storage()?.directory == target)
        #expect(try installation.requestedStorageDirectory() == target)
        for name in ["Work", "CompilationCache", "Build"] {
            #expect(try Data(contentsOf: source.directory.appending(path: name).appending(path: "data")) == Data("retained job data".utf8))
            #expect(try Data(contentsOf: target.appending(path: name).appending(path: "data")) == Data("retained job data".utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: target.appending(path: name).path(percentEncoded: false))
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        let originalCacheAttributes = try FileManager.default.attributesOfItem(atPath: source.compilationCacheDirectory.path(percentEncoded: false))
        #expect((originalCacheAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o555)
        let updated = try Data(contentsOf: registration.appending(path: ".runner"))
        #expect(updated.starts(with: [0xEF, 0xBB, 0xBF]))
        let object = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(object["workFolder"] as? String == migrated.workDirectory.appending(path: "runner-one").path(percentEncoded: false))
        #expect(object["agentId"] as? Int == 12)
        #expect((object["unknownSetting"] as? [String: Bool])?["retained"] == true)
        #expect(try Data(contentsOf: registration.appending(path: ".credentials")) == credentials)
        #expect(try Data(contentsOf: target.appending(path: "unrelated")) == Data("unrelated files".utf8))
        #expect(try await installation.prepareStorageForLaunch().directory == target)
    }

    @Test func compilationCacheSymlinkCopiesItsContentsInsteadOfLinkingBack() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: source.compilationCacheDirectory)
        let physicalCache = root.appending(path: "Physical cache")
        try FileManager.default.createDirectory(at: physicalCache, withIntermediateDirectories: true)
        try Data("cached output".utf8).write(to: physicalCache.appending(path: "output"))
        try FileManager.default.createSymbolicLink(at: source.compilationCacheDirectory, withDestinationURL: physicalCache)
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        let migrated = try await installation.prepareStorageForLaunch()
        #expect(migrated.directory == target)
        #expect(try migrated.compilationCacheDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try Data(contentsOf: migrated.compilationCacheDirectory.appending(path: "output")) == Data("cached output".utf8))
        #expect(try Data(contentsOf: physicalCache.appending(path: "output")) == Data("cached output".utf8))
    }

    @Test func runnerWorkAliasUsesItsPhysicalLocationAndMigratesItsContents() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try runner("runner-one", installation: installation, storage: source)
        let work = source.workDirectory.appending(path: "runner-one")
        try FileManager.default.removeItem(at: work)
        let physicalWork = root.appending(path: "Existing checkout")
        try FileManager.default.createDirectory(at: physicalWork, withIntermediateDirectories: true)
        try Data("checkout".utf8).write(to: physicalWork.appending(path: "source"))
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: physicalWork)
        let file = directory.appending(path: ".runner")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["workFolder"] = try physicalWork.compilerCanonicalURL().path(percentEncoded: false)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(try await installation.prepareStorageForLaunch().directory == source.directory)
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        let migrated = try await installation.prepareStorageForLaunch()
        let newWork = migrated.workDirectory.appending(path: "runner-one")
        #expect(migrated.directory == target)
        #expect(try newWork.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try Data(contentsOf: newWork.appending(path: "source")) == Data("checkout".utf8))
        #expect(try Data(contentsOf: physicalWork.appending(path: "source")) == Data("checkout".utf8))
        let updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(updated["workFolder"] as? String == newWork.path(percentEncoded: false))
    }

    @Test func destinationCollisionPreservesFilesAndCanBeResolvedByAnotherSelection() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try runner("runner-one", installation: installation, storage: source)
        let original = try Data(contentsOf: registration.appending(path: ".runner"))
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        try FileManager.default.createDirectory(at: target.appending(path: "Work"), withIntermediateDirectories: true)
        try Data("foreign checkout".utf8).write(to: target.appending(path: "Work/foreign"))
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == source.directory)
        #expect(try Data(contentsOf: registration.appending(path: ".runner")) == original)
        #expect(try Data(contentsOf: target.appending(path: "Work/foreign")) == Data("foreign checkout".utf8))
        let third = try await choose(root.appending(path: "Third"), installation: installation)
        #expect(try await installation.prepareStorageForLaunch().directory == third)
    }

    @Test func individualServicesAreExcludedAndHostedAmbiguityPreventsMigration() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try runner("runner-one", installation: installation, storage: source)
        try Data().write(to: registration.appending(path: ".service"))
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == source.directory)
        try FileManager.default.removeItem(at: registration.appending(path: ".service"))
        let outside = HostInstallation.Storage(directory: root.appending(path: "Individual storage"))
        let individual = try runner("individual", installation: installation, storage: outside, hosted: false)
        try Data().write(to: individual.appending(path: ".service"))
        let original = try Data(contentsOf: individual.appending(path: ".runner"))
        #expect(try await installation.prepareStorageForLaunch().directory == target)
        #expect(try Data(contentsOf: individual.appending(path: ".runner")) == original)
    }

    @Test func registrationWriteFailureRestoresPriorChangesAndPreservesSource() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try runner("runner-one", installation: installation, storage: source)
        let second = try runner("runner-two", installation: installation, storage: source)
        let originals = try [first, second].map { try Data(contentsOf: $0.appending(path: ".runner")) }
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: second.appending(path: ".runner").path(percentEncoded: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: second.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path(percentEncoded: false)) }
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == source.directory)
        for (directory, data) in zip([first, second], originals) {
            #expect(try Data(contentsOf: directory.appending(path: ".runner")) == data)
        }
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "Work").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: source.workDirectory.path(percentEncoded: false)))
    }

    @Test func interruptedMigrationRestoresOriginalBytesEvenIfDesiredWasChangedBack() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try runner("runner-one", installation: installation, storage: source)
        let file = directory.appending(path: ".runner")
        let original = try Data(contentsOf: file)
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        let token = UUID().uuidString
        let copy = target.appending(path: "Work")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data(token.utf8).write(to: copy.appending(path: ".xcode-runner-migration-\(token)"))
        let journal: [String: Any] = [
            "source": source.directory.absoluteString, "target": target.absoluteString,
            "staging": target.appending(path: ".xcode-runner-migration-\(token)").absoluteString,
            "token": token, "registrations": [["file": file.absoluteString, "data": original.base64EncodedString()]],
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: installation.hostRoot.appending(path: "storage-migration.json"))
        try Data(#"{"workFolder":"interrupted"}"#.utf8).write(to: file)
        _ = try await installation.requestStorageDirectory(source.directory)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try Data(contentsOf: file) == original)
        #expect(try installation.storage()?.directory == source.directory)
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        #expect(try await installation.prepareStorageForLaunch().directory == source.directory)
    }
}
