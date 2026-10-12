import Foundation
import Testing
@testable import XcodeRunnerKit

struct HostInstallationTests {
    @Test func initializesOneParentAndPreservesExistingJobData() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        #expect(try installation.storage()?.directory == nil)
        #expect(!FileManager.default.fileExists(atPath: installation.hostRoot.path(percentEncoded: false)))
        let directory = root.appending(path: "Job data")
        let cache = directory.appending(path: "CompilationCache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let retained = cache.appending(path: "retained")
        try Data("cached result".utf8).write(to: retained)
        let storage = try installation.initializeStorage(at: directory)
        let physicalDirectory = try directory.compilerCanonicalURL()
        #expect(storage.directory.path(percentEncoded: false) == physicalDirectory.path(percentEncoded: false))
        #expect(FileManager.default.fileExists(atPath: storage.workDirectory.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: storage.buildDirectory.path(percentEncoded: false)))
        let repeated = try installation.initializeStorage()
        #expect(repeated.directory == storage.directory)
        #expect(try installation.initializeStorage(at: directory).directory == storage.directory)
        #expect(try Data(contentsOf: retained) == Data("cached result".utf8))
        #expect(try installation.storage()?.directory == storage.directory)
    }

    @Test func initialSetupDoesNotSwitchExistingStorage() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        let storage = try installation.initializeStorage(at: root.appending(path: "First"))
        let retained = storage.workDirectory.appending(path: "retained")
        try Data("checkout".utf8).write(to: retained)
        #expect(throws: HostInstallation.ConfigurationError.self) {
            try installation.initializeStorage(at: root.appending(path: "Second"))
        }
        #expect(try installation.storage()?.directory == storage.directory)
        #expect(try Data(contentsOf: retained) == Data("checkout".utf8))
    }

    @Test func initialSelectionStoresThePhysicalParentOfAnAlias() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        let directory = root.appending(path: "Existing job data")
        let cache = directory.appending(path: "CompilationCache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let retained = cache.appending(path: "retained")
        try Data("cached result".utf8).write(to: retained)
        let alias = root.appending(path: "Chosen alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)

        let storage = try installation.initializeStorage(at: alias)
        let physicalDirectory = try directory.compilerCanonicalURL()
        #expect(storage.directory == physicalDirectory)
        #expect(try installation.storage()?.directory == physicalDirectory)
        #expect(installation.environment(for: storage)["XCODE_RUNNER_HOST_STORAGE_DIRECTORY"] == physicalDirectory.path(percentEncoded: false))
        #expect(storage.compilationCacheDirectory == physicalDirectory.appending(path: "CompilationCache"))
        #expect(try Data(contentsOf: retained) == Data("cached result".utf8))
    }

    @Test func runningHostEnvironmentKeepsItsActualStorageSnapshot() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        let active = try installation.initializeStorage(at: root.appending(path: "Active"))
        let environment = installation.environment(for: active).merging(["HOME": "/different/home"]) { _, value in value }
        let laterDirectory = root.appending(path: "Later")
        #expect(throws: (any Error).self) { try installation.saveStorageDirectory(laterDirectory) }
        #expect(!FileManager.default.fileExists(atPath: laterDirectory.path(percentEncoded: false)))
        #expect(try installation.storage()?.directory == active.directory)
        try FileManager.default.createDirectory(at: laterDirectory, withIntermediateDirectories: false)
        let later = try installation.saveStorageDirectory(laterDirectory)
        let configuration = try HostInstallation.hostedConfiguration(environment: environment)
        let inherited = try #require(configuration)
        #expect(inherited.storage.directory == active.directory)
        #expect(inherited.poolDirectory == installation.poolDirectory)
        #expect(try installation.storage()?.directory == later.directory)
        #expect(try HostInstallation.hostedConfiguration(environment: [:])?.poolDirectory == nil)
    }
}
