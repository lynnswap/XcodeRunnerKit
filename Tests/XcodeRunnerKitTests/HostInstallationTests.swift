import Foundation
import Testing
@testable import XcodeRunnerKit

struct HostInstallationTests {
    @Test func buildServiceConfigurationPreservesAnExecutableAliasAndCanBeCleared() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        #expect(try installation.buildServiceExecutableURL() == nil)
        #expect(try installation.saveBuildServiceExecutableURL(nil) == nil)
        let directory = root.appending(path: "Service version")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appending(path: "BuildService"))
        let alias = root.appending(path: "Current service")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let executable = alias.appending(path: "BuildService").standardizedFileURL

        #expect(try installation.saveBuildServiceExecutableURL(executable) == executable)
        #expect(try installation.buildServiceExecutableURL() == executable)
        #expect(try installation.buildServiceExecutableURL() != executable.resolvingSymlinksInPath())
        #expect(try installation.saveBuildServiceExecutableURL(nil) == nil)
        #expect(try installation.buildServiceExecutableURL() == nil)
    }

    @Test func hostedBuildServiceConfigurationUsesTheSuppliedRootAndReloadsItsRecord() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        let storage = HostInstallation.Storage(directory: root.appending(path: "Active storage"))
        let environment = installation.environment(for: storage).merging(["HOME": "/different/home"]) { _, value in value }
        #expect(try HostInstallation.hostedConfiguration(environment: environment)?.buildServiceExecutableURL == nil)
        let executable = root.appending(path: "BuildService")
        try installation.saveBuildServiceExecutableURL(executable)

        let configured = try #require(try HostInstallation.hostedConfiguration(environment: environment))
        #expect(configured.buildServiceExecutableURL == executable)
        #expect(configured.storage.directory == storage.directory)
        #expect(configured.poolDirectory == installation.poolDirectory)
        try installation.saveBuildServiceExecutableURL(nil)
        #expect(try HostInstallation.hostedConfiguration(environment: environment)?.buildServiceExecutableURL == nil)
    }

    @Test func invalidOrUnreadableBuildServiceRecordsAreReported() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        try FileManager.default.createDirectory(at: installation.hostRoot, withIntermediateDirectories: true)
        let record = installation.hostRoot.appending(path: "build-service-path")
        let environment = installation.environment(for: .init(directory: root.appending(path: "Storage")))
        try Data("relative/service".utf8).write(to: record)
        #expect(throws: HostInstallation.ConfigurationError.self) {
            try HostInstallation.hostedConfiguration(environment: environment)
        }
        // Pool commands do not depend on the build service record.
        #expect(try HostInstallation.hostedPoolDirectory(environment: environment) == installation.poolDirectory)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try HostInstallation.hostedConfiguration(environment: environment)
        }
    }

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
