import Foundation
import Testing
@testable import XcodeRunnerHost

@MainActor
struct HostSettingsTests {
    private func model(at root: URL) throws -> HostSettingsModel {
        try HostSettingsModel(
            hostRoot: root.appending(path: "Host"), runnersRoot: root.appending(path: "Runners"),
            logsDirectory: root.appending(path: "Separate logs")
        )
    }

    @Test func readsDoNotConfigurePoolAndApplyUsesHostRoot() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = try model(at: root)
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
        #expect(settings.pool.directory == settings.hostRoot.appending(path: "Pool"))
        #expect(settings.compilationCache == settings.hostRoot.appending(path: "CompilationCache"))
        #expect(!FileManager.default.fileExists(atPath: settings.logsDirectory.appending(path: "Pool").path()))
        try FileManager.default.removeItem(at: root)
    }

    @Test func refreshPreservesEditsAndShowsExternalCapacityChanges() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = try model(at: root)
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
        let settings = try model(at: root)
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
        let settings = try model(at: root)
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

    @Test func shrinkingLimitShowsJobsStillRunning() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = try model(at: root)
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
        let settings = try model(at: root)
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
        for _ in 0..<100 {
            await settings.refreshPoolStatus()
            if settings.poolStatus?.waitingJobCounts.total == 3 { break }
            try await Task.sleep(for: .milliseconds(50))
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

    @Test func runnerStorageComesFromRegistration() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "installation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appending(path: ".runner")
        try Data(#"{"agentName":"repository-runner","workFolder":"../Work data"}"#.utf8).write(to: metadata)
        let runner = RunnerSettingsRow.read(directory: directory, state: .running, logsDirectory: root.appending(path: "Logs"))
        #expect(runner.name == "repository-runner")
        #expect(runner.workDirectory == root.appending(path: "Work data", directoryHint: .isDirectory).standardizedFileURL)
        #expect(runner.configurationError == nil)
        try Data("invalid JSON".utf8).write(to: metadata)
        let invalid = RunnerSettingsRow.read(directory: directory, state: .failed, logsDirectory: root.appending(path: "Logs"))
        #expect(invalid.configurationError != nil)
        #expect(invalid.workDirectory == nil)
        #expect(invalid.state == .failed)
        try FileManager.default.removeItem(at: root)
    }

    @Test func readFailureDoesNotPresentOldStatusAsCurrent() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let settings = try model(at: root)
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

    @Test func individualServiceDoesNotUseStaleHostLog() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "installation")
        let logs = root.appending(path: "Host logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(#"{"agentName":"repository-runner","workFolder":"_work"}"#.utf8).write(to: directory.appending(path: ".runner"))
        let formerHostLog = logs.appending(path: "installation.log")
        try Data("Previous host service log".utf8).write(to: formerHostLog)
        let individual = RunnerSettingsRow.read(directory: directory, state: .individualService, logsDirectory: logs)
        #expect(individual.log == nil)
        #expect(individual.configurationError == nil)
        let hosted = RunnerSettingsRow.read(directory: directory, state: .running, logsDirectory: logs)
        #expect(hosted.log == formerHostLog)
        try FileManager.default.removeItem(at: root)
    }

    @Test func customHostRootDoesNotDependOnLogLocation() throws {
        let options = try HostOptions.parse(["--host-root", "/tmp/Host data", "--logs-directory", "/tmp/Service logs"])
        #expect(options.hostRoot == "/tmp/Host data")
        #expect(options.logsDirectory == "/tmp/Service logs")
    }
}
