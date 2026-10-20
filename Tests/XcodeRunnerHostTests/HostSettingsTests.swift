import Foundation
import Testing
import XcodeRunnerHostSupport
import XcodeRunnerKit
@testable import XcodeRunnerHost

@MainActor @Suite(.timeLimit(.minutes(1)))
struct HostSettingsTests {
    private func model(at root: URL) -> HostSettingsModel {
        HostSettingsModel(installation: HostInstallation(homeDirectory: root.appending(path: "Home")))
    }

    @Test func readsDoNotConfigurePoolAndApplyUsesHostRoot() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = model(at: root)
        #expect(!settings.hasLoadedPoolStatus)
        await settings.applyCapacity()
        #expect(!FileManager.default.fileExists(atPath: settings.pool.directory.path()))
        await settings.refreshPoolStatus()
        #expect(settings.hasLoadedPoolStatus)
        #expect(settings.poolStatus == nil)
        #expect(!FileManager.default.fileExists(atPath: settings.pool.directory.path()))
        settings.capacityInput = "6"
        await settings.applyCapacity()
        #expect(settings.saveError == nil)
        #expect(settings.poolStatus?.maximumConcurrentJobs == 6)
        #expect(settings.poolStatus?.activeJobCount == 0)
        #expect(settings.poolStatus?.waitingJobCounts.total == 0)
        #expect(settings.pool.directory == settings.installation.poolDirectory)
        try FileManager.default.removeItem(at: root)
    }

    @Test func refreshPreservesEditsAndShowsExternalCapacityChanges() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = model(at: root)
        await settings.refreshPoolStatus()
        settings.capacityInput = "6"
        await settings.applyCapacity()
        settings.capacityInput = "3"
        try await settings.pool.updateMaximumConcurrentJobs(to: 4)
        await settings.refreshPoolStatus()
        #expect(settings.poolStatus?.maximumConcurrentJobs == 4)
        #expect(settings.capacityInput == "3")
        await settings.applyCapacity()
        #expect(settings.poolStatus?.maximumConcurrentJobs == 3)
        try await settings.pool.updateMaximumConcurrentJobs(to: 2)
        await settings.refreshPoolStatus()
        #expect(settings.capacityInput == "2")
        try FileManager.default.removeItem(at: root)
    }

    @Test func firstReadPreservesInputWhileLoadingSavedLimit() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = model(at: root)
        try await settings.pool.updateMaximumConcurrentJobs(to: 6)
        settings.capacityInput = "3"
        await settings.applyCapacity()
        #expect(!settings.hasLoadedPoolStatus)
        await settings.refreshPoolStatus()
        #expect(settings.poolStatus?.maximumConcurrentJobs == 6)
        #expect(settings.capacityInput == "3")
        await settings.applyCapacity()
        #expect(settings.poolStatus?.maximumConcurrentJobs == 3)
        try FileManager.default.removeItem(at: root)
    }

    @Test func invalidInputDoesNotReplaceSavedCapacity() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = model(at: root)
        await settings.refreshPoolStatus()
        await settings.applyCapacity()
        for input in ["0", "-1", "1.5", ""] {
            settings.capacityInput = input
            await settings.applyCapacity()
            #expect(settings.saveError != nil)
            #expect(settings.poolStatus?.maximumConcurrentJobs == 4)
            #expect(!settings.isSaving)
        }
        settings.capacityInput = "2"
        await settings.applyCapacity()
        #expect(settings.saveError == nil)
        #expect(settings.poolStatus?.maximumConcurrentJobs == 2)
        try FileManager.default.removeItem(at: root)
    }

    @Test func poolWriteFailureDoesNotSaveRepositorySelection() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        try GitHubHostConfiguration(repositories: [repository]).save(to: record)
        let settings = model(at: root)
        try await settings.pool.updateMaximumConcurrentJobs(to: 4)
        await settings.refreshPoolStatus()
        let lock = settings.pool.directory.appending(path: "pool.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        settings.github.selectedRepositoryIDs = []
        settings.capacityInput = "6"

        await settings.applyCapacity()

        #expect(settings.saveError?.contains("Could not save the execution limit") == true)
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [repository])
        #expect(try String(contentsOf: settings.pool.directory.appending(path: "capacity"), encoding: .utf8) == "4")
        #expect(!settings.isSaving)
    }

    @Test func selectionWriteFailureReportsTheSavedExecutionLimit() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installation.hostRoot.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: root)
        }
        let record = installation.hostRoot.appending(path: "github-host.json")
        let repository = GitHubRepository(id: 1, fullName: "owner/Project")
        try GitHubHostConfiguration(repositories: [repository]).save(to: record)
        let settings = model(at: root)
        try await settings.pool.updateMaximumConcurrentJobs(to: 4)
        await settings.refreshPoolStatus()
        settings.github.selectedRepositoryIDs = []
        settings.capacityInput = "6"
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installation.hostRoot.path(percentEncoded: false))

        await settings.applyCapacity()

        #expect(settings.poolStatus?.maximumConcurrentJobs == 6)
        #expect(try await settings.pool.status()?.maximumConcurrentJobs == 6)
        #expect(try GitHubHostConfiguration.load(from: record).repositories == [repository])
        #expect(settings.saveError?.contains("execution limit was saved as 6") == true)
        #expect(settings.saveError?.contains("repository selection could not be saved") == true)
        #expect(!settings.isSaving)
    }

    @Test func shrinkingLimitShowsJobsStillRunning() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = model(at: root)
        await settings.refreshPoolStatus()
        settings.capacityInput = "2"
        await settings.applyCapacity()
        let started = AsyncStream<Void>.makeStream()
        let jobs = (0..<2).map { _ in
            let finish = AsyncStream<Void>.makeStream()
            let job = Task {
                try await settings.pool.withSlot {
                    started.continuation.yield()
                    for await _ in finish.stream { break }
                }
            }
            return (job: job, finish: finish.continuation)
        }
        var events = started.stream.makeAsyncIterator()
        await events.next()
        await events.next()
        settings.capacityInput = "1"
        await settings.applyCapacity()
        #expect(settings.poolStatus?.activeJobCount == 2)
        #expect(settings.admissionMessage == "Existing jobs will finish. New jobs wait until the running count falls below the limit.")
        for job in jobs { job.finish.finish() }
        for job in jobs { try await job.job.value }
        await settings.refreshPoolStatus()
        #expect(settings.poolStatus?.activeJobCount == 0)
        try FileManager.default.removeItem(at: root)
    }

    @Test func refreshShowsSharedWaitingCountsByPriority() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = model(at: root)
        await settings.refreshPoolStatus()
        settings.capacityInput = "1"
        await settings.applyCapacity()
        let started = AsyncStream<Void>.makeStream()
        let finish = AsyncStream<Void>.makeStream()
        let active = Task {
            try await settings.pool.withSlot {
                started.continuation.yield()
                for await _ in finish.stream { break }
            }
        }
        var events = started.stream.makeAsyncIterator()
        await events.next()
        let high = Task { try await settings.pool.withSlot(priority: .high) {} }
        let medium = Task { try await settings.pool.withSlot(priority: .medium) {} }
        let low = Task { try await settings.pool.withSlot(priority: .low) {} }
        defer {
            finish.continuation.finish()
            for job in [active, high, medium, low] { job.cancel() }
        }
        try await waitUntil {
            await settings.refreshPoolStatus()
            return settings.poolStatus?.waitingJobCounts.total == 3
        }
        #expect(settings.poolStatus?.activeJobCount == 1)
        #expect(settings.poolStatus?.waitingJobCounts.high == 1)
        #expect(settings.poolStatus?.waitingJobCounts.medium == 1)
        #expect(settings.poolStatus?.waitingJobCounts.low == 1)
        #expect(settings.capacityInput == "1")

        medium.cancel()
        do {
            try await medium.value
            Issue.record("The cancelled waiting job completed without cancellation.")
        } catch is CancellationError {}
        await settings.refreshPoolStatus()
        #expect(settings.poolStatus?.waitingJobCounts.high == 1)
        #expect(settings.poolStatus?.waitingJobCounts.medium == 0)
        #expect(settings.poolStatus?.waitingJobCounts.low == 1)

        finish.continuation.finish()
        for job in [active, high, low] { try await job.value }
        await settings.refreshPoolStatus()
        #expect(settings.poolStatus?.activeJobCount == 0)
        #expect(settings.poolStatus?.waitingJobCounts.total == 0)
        try FileManager.default.removeItem(at: root)
    }

    @Test func runnerNameComesFromRegistrationAndReportsReadFailures() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "installation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appending(path: ".runner")
        try Data(#"{"agentName":"repository-runner"}"#.utf8).write(to: metadata)
        let runner = RunnerSettingsRow.read(RunnerDirectory(url: directory), state: .running)
        #expect(runner.name == "repository-runner")
        #expect(runner.configurationError == nil)
        try Data("invalid JSON".utf8).write(to: metadata)
        let invalid = RunnerSettingsRow.read(RunnerDirectory(url: directory), state: .failed)
        #expect(invalid.configurationError != nil)
        #expect(invalid.state == .failed)
        try FileManager.default.removeItem(at: root)
    }

    @Test func readFailureDoesNotPresentOldStatusAsCurrent() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = model(at: root)
        await settings.refreshPoolStatus()
        await settings.applyCapacity()
        #expect(settings.poolStatus?.maximumConcurrentJobs == 4)
        try FileManager.default.removeItem(at: settings.pool.directory)
        try Data().write(to: settings.pool.directory)
        await settings.refreshPoolStatus()
        #expect(settings.poolStatus == nil)
        #expect(settings.poolError != nil)
        #expect(settings.admissionMessage == "The execution pool is unavailable.")
        try FileManager.default.removeItem(at: root)
    }

    @Test func installedPathsComeFromOneHomeDirectory() throws {
        let options = try HostOptions.parse(["--home-directory", "/tmp/Fixture home"])
        #expect(options.installation.hostRoot == URL(filePath: "/tmp/Fixture home/Library/Application Support/XcodeRunnerKit"))
        #expect(options.installation.logsDirectory == options.installation.hostRoot.appending(path: "logs/runners"))
    }

    @Test func storageSaveKeepsRunningSnapshotAndDisplaysOnePendingFolder() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        let active = try installation.initializeStorage(at: root.appending(path: "Active"))
        let settings = HostSettingsModel(installation: installation)
        settings.storageDidBecomeAvailable(active)
        settings.hostState = .running
        let next = root.appending(path: "Next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        let alias = root.appending(path: "Chosen folder")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: next)
        let physicalNext = URL(filePath: try #require(next.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath))
        settings.storageDirectoryInput = alias.path(percentEncoded: false)
        await settings.saveStorageSelection()
        #expect(settings.storageSaveError == nil)
        #expect(settings.activeStorage?.directory == active.directory)
        #expect(try installation.storage()?.directory == active.directory)
        #expect(settings.savedStorageDirectory == (try installation.requestedStorageDirectory()))
        #expect(settings.savedStorageDirectory == physicalNext)
        #expect(settings.storageDirectoryInput == physicalNext.path(percentEncoded: false))
        #expect(settings.storageMessage == "Saved for the next host launch. Running jobs continue using their current storage.")
        #expect(settings.hostState == .running)
    }

    @Test func storageSavePreservesSelectionsUntilCurrentConfigurationIsRepaired() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root.appending(path: "Home"))
        let active = try installation.initializeStorage(at: root.appending(path: "Active"))
        let settings = HostSettingsModel(installation: installation)
        settings.storageDidBecomeAvailable(active)
        settings.hostState = .running
        let previous = root.appending(path: "Previous selection")
        let next = root.appending(path: "Next selection")
        for folder in [previous, next] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        settings.storageDirectoryInput = previous.path(percentEncoded: false)
        await settings.saveStorageSelection()
        #expect(settings.storageSaveError == nil)
        let saved = try #require(settings.savedStorageDirectory)
        let activeRecord = installation.hostRoot.appending(path: "storage-directory")
        let pendingRecord = installation.hostRoot.appending(path: "requested-storage-directory")
        let originalActive = try Data(contentsOf: activeRecord)
        let originalPending = try Data(contentsOf: pendingRecord)
        let malformed = Data("invalid current storage setting".utf8)
        try malformed.write(to: activeRecord, options: .atomic)

        settings.storageDirectoryInput = next.path(percentEncoded: false)
        await settings.saveStorageSelection()
        #expect(settings.storageSaveError != nil)
        #expect(settings.savedStorageDirectory == saved)
        #expect(settings.storageDirectoryInput == next.path(percentEncoded: false))
        #expect(settings.activeStorage?.directory == active.directory)
        #expect(settings.hostState == .running)
        #expect(try Data(contentsOf: activeRecord) == malformed)
        #expect(try Data(contentsOf: pendingRecord) == originalPending)

        try originalActive.write(to: activeRecord, options: .atomic)
        await settings.saveStorageSelection()
        let physicalNext = URL(filePath: try #require(next.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath))
        #expect(settings.storageSaveError == nil)
        #expect(settings.savedStorageDirectory == physicalNext)
        #expect(try installation.requestedStorageDirectory() == physicalNext)
        #expect(settings.storageDirectoryInput == physicalNext.path(percentEncoded: false))
        #expect(try Data(contentsOf: activeRecord) == originalActive)
        #expect(try installation.storage()?.directory == active.directory)
    }

    @Test func storageSelectionRemainsUsableAfterStartupFailure() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = model(at: root)
        settings.storagePreparationFailed(CocoaError(.fileWriteNoPermission))
        #expect(settings.hostState == .needsAttention)
        #expect(settings.storageError != nil)
        settings.storageDirectoryInput = "relative/folder"
        await settings.saveStorageSelection()
        #expect(settings.storageSaveError != nil)
        let next = root.appending(path: "Next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        settings.storageDirectoryInput = next.path(percentEncoded: false)
        await settings.saveStorageSelection()
        #expect(settings.storageSaveError == nil)
        #expect(settings.storageError != nil)
        #expect(settings.activeStorage == nil)
        #expect(settings.hostState == .needsAttention)
    }
}
