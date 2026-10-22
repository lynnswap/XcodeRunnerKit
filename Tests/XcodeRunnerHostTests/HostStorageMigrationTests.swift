import Foundation
import Testing
@testable import XcodeRunnerHostSupport

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

    @Test func unavailableFirstSavedParentIsNotRecreatedBeforeRunnerStartup() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        let selected = try await choose(root.appending(path: "Selected storage"), installation: installation)
        let disconnected = root.appending(path: "Disconnected storage")
        let retained = Data("existing job data".utf8)
        try retained.write(to: selected.appending(path: "retained"))
        try FileManager.default.moveItem(at: selected, to: disconnected)

        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage() == nil)
        #expect(try installation.requestedStorageDirectory() == selected)
        #expect(!FileManager.default.fileExists(atPath: selected.path(percentEncoded: false)))
        #expect(try Data(contentsOf: disconnected.appending(path: "retained")) == retained)

        try FileManager.default.moveItem(at: disconnected, to: selected)
        #expect(try await installation.prepareStorageForLaunch().directory == selected)
        #expect(try Data(contentsOf: selected.appending(path: "retained")) == retained)
    }

    @Test func unchangedStoragePreparesMissingManagedDirectoriesBeforeRunnerStartup() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [source.workDirectory, source.compilationCacheDirectory, source.buildDirectory] {
            try FileManager.default.removeItem(at: directory)
        }
        let prepared = try await installation.prepareStorageForLaunch()
        #expect(prepared.directory == source.directory)
        for directory in [prepared.workDirectory, prepared.compilationCacheDirectory, prepared.buildDirectory] {
            #expect(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }
        #expect(try installation.storage()?.directory == source.directory)
    }

    @Test func removedManagedWorkFolderIsNotRecreatedAtLaunchAndCanBeCreatedAfterRelocation() async throws {
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
    }

    @Test func unavailableStorageParentPreservesPendingChangeUntilSourceReturns() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try runner("runner-one", installation: installation, storage: source)
        let file = registration.appending(path: ".runner")
        let original = try Data(contentsOf: file)
        let data = Data("retained build output".utf8)
        try data.write(to: source.buildDirectory.appending(path: "output"))
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        let unavailable = root.appending(path: "Disconnected storage")
        try FileManager.default.moveItem(at: source.directory, to: unavailable)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == source.directory)
        #expect(try installation.requestedStorageDirectory() == target)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path(percentEncoded: false)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installation.hostRoot.appending(path: "storage-migration.json").path(percentEncoded: false)))
        #expect(try Data(contentsOf: unavailable.appending(path: "Build/output")) == data)
        try FileManager.default.moveItem(at: unavailable, to: source.directory)
        let migrated = try await installation.prepareStorageForLaunch()
        #expect(migrated.directory == target)
        #expect(try Data(contentsOf: migrated.buildDirectory.appending(path: "output")) == data)
        #expect(try Data(contentsOf: source.buildDirectory.appending(path: "output")) == data)
    }

    @Test func removedRunnerFolderUnderManagedWorkAliasCanLaunchAndRelocate() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try runner("runner-one", installation: installation, storage: source)
        let metadata = directory.appending(path: ".runner")
        let credentials = try Data(contentsOf: directory.appending(path: ".credentials"))
        let externalWork = root.appending(path: "External work")
        try FileManager.default.moveItem(at: source.workDirectory, to: externalWork)
        try FileManager.default.createSymbolicLink(at: source.workDirectory, withDestinationURL: externalWork)
        let physicalWork = try externalWork.compilerCanonicalURL()
        let physicalRunnerWork = try physicalWork.appending(path: "runner-one").compilerCanonicalURL()
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        object["workFolder"] = physicalRunnerWork.path(percentEncoded: false)
        let original = Data([0xEF, 0xBB, 0xBF]) + (try JSONSerialization.data(withJSONObject: object))
        try original.write(to: metadata)
        let retained = Data("retained work data".utf8)
        try retained.write(to: physicalWork.appending(path: "retained"))
        try FileManager.default.removeItem(at: physicalRunnerWork)

        #expect(try await installation.prepareStorageForLaunch().directory == source.directory)
        #expect(try Data(contentsOf: metadata) == original)
        #expect(!FileManager.default.fileExists(atPath: physicalRunnerWork.path(percentEncoded: false)))
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        let migrated = try await installation.prepareStorageForLaunch()
        #expect(migrated.directory == target)
        let updated = try Data(contentsOf: metadata)
        #expect(updated.starts(with: [0xEF, 0xBB, 0xBF]))
        let registration = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(registration["workFolder"] as? String == migrated.workDirectory.appending(path: "runner-one").path(percentEncoded: false))
        #expect(registration["agentId"] as? Int == 12)
        #expect((registration["unknownSetting"] as? [String: Bool])?["retained"] == true)
        #expect(try Data(contentsOf: directory.appending(path: ".credentials")) == credentials)
        #expect(try Data(contentsOf: migrated.workDirectory.appending(path: "retained")) == retained)
        #expect(try Data(contentsOf: physicalWork.appending(path: "retained")) == retained)
        #expect(try source.workDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(!FileManager.default.fileExists(atPath: physicalRunnerWork.path(percentEncoded: false)))
    }

    @Test func savedSelectionDoesNotChangeRunningStorageAndCopiesOnNextLaunch() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try runner(".hidden-one", installation: installation, storage: source)
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
        #expect(object["workFolder"] as? String == migrated.workDirectory.appending(path: ".hidden-one").path(percentEncoded: false))
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

    @Test(arguments: ["CompilationCache", "Work/runner-one"])
    func unavailableCopyAliasPreservesPendingChangeUntilTargetReturns(_ relativePath: String) async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try runner("runner-one", installation: installation, storage: source)
        let file = registration.appending(path: ".runner")
        let original = try Data(contentsOf: file)
        let alias = source.directory.appending(path: relativePath)
        try FileManager.default.removeItem(at: alias)
        let physical = root.appending(path: "Linked data")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: false)
        let content = Data("retained linked output".utf8)
        try content.write(to: physical.appending(path: "output"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let unavailable = root.appending(path: "Disconnected data")
        try FileManager.default.moveItem(at: physical, to: unavailable)
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == source.directory)
        #expect(try installation.requestedStorageDirectory() == target)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path(percentEncoded: false)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installation.hostRoot.appending(path: "storage-migration.json").path(percentEncoded: false)))
        #expect(try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try Data(contentsOf: unavailable.appending(path: "output")) == content)
        try FileManager.default.moveItem(at: unavailable, to: physical)
        let migrated = try await installation.prepareStorageForLaunch()
        #expect(migrated.directory == target)
        #expect(try Data(contentsOf: target.appending(path: relativePath).appending(path: "output")) == content)
        #expect(try Data(contentsOf: physical.appending(path: "output")) == content)
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
        let original = try Data(contentsOf: file)
        let nestedTarget = try await choose(physicalWork.appending(path: "NewStorage"), installation: installation)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: nestedTarget.path(percentEncoded: false)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installation.hostRoot.appending(path: "storage-migration.json").path(percentEncoded: false)))
        #expect(try installation.storage()?.directory == source.directory)
        #expect(try Data(contentsOf: file) == original)
        #expect(try work.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try Data(contentsOf: physicalWork.appending(path: "source")) == Data("checkout".utf8))
        let target = try await choose(source.directory.appending(path: "NewStorage"), installation: installation)
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
        let brokenTarget = try await choose(root.appending(path: "Existing link destination"), installation: installation)
        let brokenWork = brokenTarget.appending(path: "Work")
        let linkedPath = root.appending(path: "Unavailable foreign checkout").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: brokenWork.path(percentEncoded: false), withDestinationPath: linkedPath)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == source.directory)
        #expect(try installation.requestedStorageDirectory() == brokenTarget)
        #expect(try Data(contentsOf: registration.appending(path: ".runner")) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: brokenWork.path(percentEncoded: false)) == linkedPath)
        #expect(!FileManager.default.fileExists(atPath: installation.hostRoot.appending(path: "storage-migration.json").path(percentEncoded: false)))
        let third = try await choose(root.appending(path: "Third"), installation: installation)
        #expect(try await installation.prepareStorageForLaunch().directory == third)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: brokenWork.path(percentEncoded: false)) == linkedPath)
        #expect(try Data(contentsOf: target.appending(path: "Work/foreign")) == Data("foreign checkout".utf8))
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
        let file = individual.appending(path: ".runner")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let workAlias = root.appending(path: "Managed work alias")
        try FileManager.default.createSymbolicLink(at: workAlias, withDestinationURL: source.workDirectory)
        let managedIndividualWork = source.workDirectory.appending(path: "individual")
        try FileManager.default.createDirectory(at: managedIndividualWork, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: individual.appending(path: "_work"), withDestinationURL: managedIndividualWork)
        let retained = Data("individual checkout".utf8)
        try retained.write(to: managedIndividualWork.appending(path: "source"))
        let hostedMetadata = try Data(contentsOf: registration.appending(path: ".runner"))
        let overlappingWorkFolders = [source.workDirectory, workAlias].map {
            $0.appending(path: "unavailable-individual").path(percentEncoded: false)
        } + ["_work"]
        for workFolder in overlappingWorkFolders {
            object["workFolder"] = workFolder
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            let original = try Data(contentsOf: file)
            await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
            #expect(try installation.storage()?.directory == source.directory)
            #expect(try installation.requestedStorageDirectory() == target)
            #expect(try Data(contentsOf: file) == original)
            #expect(try Data(contentsOf: registration.appending(path: ".runner")) == hostedMetadata)
            #expect(try Data(contentsOf: managedIndividualWork.appending(path: "source")) == retained)
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path(percentEncoded: false)).isEmpty)
        }
        object["workFolder"] = source.directory.appending(path: "Work elsewhere/individual").path(percentEncoded: false)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        try FileManager.default.removeItem(at: outside.directory)
        let original = try Data(contentsOf: file)
        #expect(try await installation.prepareStorageForLaunch().directory == target)
        #expect(try Data(contentsOf: file) == original)
        try FileManager.default.removeItem(at: target.appending(path: "Work"))
        let third = try await choose(root.appending(path: "Third"), installation: installation)
        #expect(try await installation.prepareStorageForLaunch().directory == third)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func registrationReadOrWriteFailurePreservesSourceAndCleansDestinationForRetry() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try runner("runner-one", installation: installation, storage: source)
        let second = try runner("runner-two", installation: installation, storage: source)
        let originals = try [first, second].map { try Data(contentsOf: $0.appending(path: ".runner")) }
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        let readOnlyParent = source.compilationCacheDirectory.appending(path: "Results.xcresult")
        let readOnlyChild = readOnlyParent.appending(path: ".read-only")
        let outside = root.appending(path: "Outside migration")
        let content = Data("retained readonly output".utf8)
        for directory in [readOnlyChild, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try content.write(to: directory.appending(path: "output"))
        }
        try FileManager.default.createSymbolicLink(at: readOnlyParent.appending(path: "outside"), withDestinationURL: outside)
        for directory in [readOnlyParent, readOnlyChild, outside] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
        }
        defer {
            for directory in [readOnlyParent, readOnlyChild, outside,
                              target.appending(path: "CompilationCache/Results.xcresult"),
                              target.appending(path: "CompilationCache/Results.xcresult/.read-only")] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
            }
        }
        let firstPermissions = try #require(FileManager.default.attributesOfItem(atPath: first.path(percentEncoded: false))[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: first.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: firstPermissions], ofItemAtPath: first.path(percentEncoded: false)) }
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == source.directory)
        #expect(try installation.requestedStorageDirectory() == target)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path(percentEncoded: false)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installation.hostRoot.appending(path: "storage-migration.json").path(percentEncoded: false)))
        try FileManager.default.setAttributes([.posixPermissions: firstPermissions], ofItemAtPath: first.path(percentEncoded: false))
        for (directory, data) in zip([first, second], originals) {
            #expect(try Data(contentsOf: directory.appending(path: ".runner")) == data)
        }
        // Scan order decides whether runner-one is rewritten before this failure. The interrupted-migration test covers restoring a rewritten registration.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: second.appending(path: ".runner").path(percentEncoded: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: second.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path(percentEncoded: false)) }
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == source.directory)
        for (directory, data) in zip([first, second], originals) {
            #expect(try Data(contentsOf: directory.appending(path: ".runner")) == data)
        }
        for name in ["Work", "CompilationCache", "Build"] {
            #expect(!FileManager.default.fileExists(atPath: target.appending(path: name).path(percentEncoded: false)))
        }
        #expect(!FileManager.default.fileExists(atPath: installation.hostRoot.appending(path: "storage-migration.json").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: source.workDirectory.path(percentEncoded: false)))
        for directory in [readOnlyParent, readOnlyChild, outside] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o555)
        }
        #expect(try Data(contentsOf: readOnlyChild.appending(path: "output")) == content)
        #expect(try Data(contentsOf: outside.appending(path: "output")) == content)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path(percentEncoded: false))
        let migrated = try await installation.prepareStorageForLaunch()
        #expect(migrated.directory == target)
        let copied = migrated.compilationCacheDirectory.appending(path: "Results.xcresult/.read-only")
        #expect(try Data(contentsOf: copied.appending(path: "output")) == content)
        let copiedAttributes = try FileManager.default.attributesOfItem(atPath: copied.path(percentEncoded: false))
        #expect((copiedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o555)
    }

    @Test func interruptedMigrationRestoresOriginalBytesEvenIfDesiredWasChangedBack() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try runner("runner-one", installation: installation, storage: source)
        let file = directory.appending(path: ".runner")
        let original = try Data(contentsOf: file)
        let content = Data("retained checkout".utf8)
        try content.write(to: source.workDirectory.appending(path: "runner-one/source"))
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
        let record = installation.hostRoot.appending(path: "storage-migration.json")
        let recorded = try JSONSerialization.data(withJSONObject: journal)
        try recorded.write(to: record)
        try Data(#"{"workFolder":"interrupted"}"#.utf8).write(to: file)
        _ = try await installation.requestStorageDirectory(source.directory)
        let unavailable = root.appending(path: "Disconnected destination")
        try FileManager.default.moveItem(at: target, to: unavailable)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try Data(contentsOf: file) == original)
        #expect(try installation.storage()?.directory == source.directory)
        #expect(try installation.requestedStorageDirectory() == source.directory)
        #expect(try Data(contentsOf: record) == recorded)
        #expect(try String(contentsOf: unavailable.appending(path: "Work/.xcode-runner-migration-\(token)"), encoding: .utf8) == token)
        try FileManager.default.moveItem(at: unavailable, to: target)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try Data(contentsOf: file) == original)
        #expect(try installation.storage()?.directory == source.directory)
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: record.path(percentEncoded: false)))
        #expect(try await installation.prepareStorageForLaunch().directory == source.directory)
        _ = try await installation.requestStorageDirectory(target)
        let migrated = try await installation.prepareStorageForLaunch()
        #expect(migrated.directory == target)
        #expect(try Data(contentsOf: migrated.workDirectory.appending(path: "runner-one/source")) == content)
    }

    @Test func committedMigrationRetainsCleanupRecordUntilDestinationReturns() async throws {
        let (root, installation, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try runner("runner-one", installation: installation, storage: source)
        let file = directory.appending(path: ".runner")
        let original = try Data(contentsOf: file)
        let content = Data("retained cache output".utf8)
        try content.write(to: source.compilationCacheDirectory.appending(path: "output"))
        let target = try await choose(root.appending(path: "Second"), installation: installation)
        _ = try await installation.prepareStorageForLaunch()
        let committedRegistration = try Data(contentsOf: file)
        let token = UUID().uuidString
        let ownershipName = ".xcode-runner-migration-\(token)"
        for name in ["Work", "CompilationCache", "Build"] {
            try Data(token.utf8).write(to: target.appending(path: name).appending(path: ownershipName))
        }
        let journal: [String: Any] = [
            "source": source.directory.absoluteString, "target": target.absoluteString,
            "staging": target.appending(path: ".xcode-runner-migration-\(token)").absoluteString,
            "token": token, "registrations": [["file": file.absoluteString, "data": original.base64EncodedString()]],
        ]
        let record = installation.hostRoot.appending(path: "storage-migration.json")
        let recorded = try JSONSerialization.data(withJSONObject: journal)
        try recorded.write(to: record)
        let unavailable = root.appending(path: "Disconnected destination")
        try FileManager.default.moveItem(at: target, to: unavailable)
        await #expect(throws: (any Error).self) { try await installation.prepareStorageForLaunch() }
        #expect(try installation.storage()?.directory == target)
        #expect(try installation.requestedStorageDirectory() == target)
        #expect(try Data(contentsOf: file) == committedRegistration)
        #expect(try Data(contentsOf: record) == recorded)
        try FileManager.default.moveItem(at: unavailable, to: target)
        #expect(try await installation.prepareStorageForLaunch().directory == target)
        #expect(!FileManager.default.fileExists(atPath: record.path(percentEncoded: false)))
        for name in ["Work", "CompilationCache", "Build"] {
            #expect(!FileManager.default.fileExists(atPath: target.appending(path: name).appending(path: ownershipName).path(percentEncoded: false)))
        }
        #expect(try Data(contentsOf: file) == committedRegistration)
        #expect(try Data(contentsOf: source.compilationCacheDirectory.appending(path: "output")) == content)
        #expect(try Data(contentsOf: target.appending(path: "CompilationCache/output")) == content)
    }
}
