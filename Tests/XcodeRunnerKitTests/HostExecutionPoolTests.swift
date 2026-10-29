import Foundation
import Testing
@testable import XcodeRunnerKit

@Suite(.timeLimit(.minutes(1)))
struct HostExecutionPoolTests {
    @Test func jobsRequireExplicitConfiguration() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = HostExecutionPool(directory: root)
        #expect(try pool.configuration() == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        do {
            try await pool.withSlot { Issue.record("An unconfigured pool admitted a job.") }
            Issue.record("An unconfigured pool returned successfully.")
        } catch HostExecutionPool.ConfigurationError.notConfigured { }

        #expect(try pool.configuration() == nil)
        let configured = try await pool.configure(maximumConcurrentJobs: 2, simulatorRetention: .forever)
        #expect(configured == HostExecutionPool.Configuration(maximumConcurrentJobs: 2, simulatorRetention: .forever))
        try await pool.withSlot { }
        #expect(try await pool.status()?.configuration == configured)
    }

    @Test func concurrentPartialUpdatesPreserveBothSettings() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = HostExecutionPool(directory: root)
        try await pool.configure(maximumConcurrentJobs: 4)

        async let capacity = pool.configure(maximumConcurrentJobs: 2)
        async let retention = pool.configure(simulatorRetention: .forever)
        _ = try await (capacity, retention)

        let reopened = HostExecutionPool(directory: root)
        #expect(try reopened.configuration() == HostExecutionPool.Configuration(
            maximumConcurrentJobs: 2, simulatorRetention: .forever
        ))
    }

    @Test func firstUpdateMigratesLegacySettingsWithoutChangingTheirValues() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("3".utf8).write(to: root.appending(path: "capacity"))
        try Data("35".utf8).write(to: root.appending(path: "simulator-idle-retention-minutes"))
        let pool = HostExecutionPool(directory: root)
        let legacy = HostExecutionPool.Configuration(maximumConcurrentJobs: 3, simulatorRetention: .idleTimeout(minutes: 35))
        #expect(try pool.configuration() == legacy)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "configuration.json").path))

        let saved = try await pool.configure()

        #expect(saved == legacy)
        #expect(try HostExecutionPool(directory: root).configuration() == legacy)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "capacity").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "simulator-idle-retention-minutes").path))
    }

    @Test func invalidUpdatesPreserveTheSavedConfiguration() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = HostExecutionPool(directory: root)
        let initial = try await pool.configure(maximumConcurrentJobs: 2, simulatorRetention: .forever)

        do {
            try await pool.configure(simulatorRetention: .idleTimeout(minutes: 0))
            Issue.record("An invalid timeout was saved.")
        } catch HostExecutionPool.ConfigurationError.invalidSimulatorRetention { }
        #expect(try pool.configuration() == initial)
    }
}
