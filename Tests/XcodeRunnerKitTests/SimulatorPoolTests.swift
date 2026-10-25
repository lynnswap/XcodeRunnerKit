import Darwin
import Foundation
import Synchronization
import Testing
@testable import XcodeRunnerKit

@Suite(.timeLimit(.minutes(1)))
struct SimulatorPoolTests {
    @Test(arguments: [Int32(0), Int32(7)])
    func completedOperationsCleanAndReuseTheSameDevice(exitCode: Int32) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = fixture.runner
        let first = try await completedResult(runner, request: fixture.request("first", exitCode: exitCode))
        let second = try await runner.run(.test, request: fixture.request("second"))

        #expect(first.status == .exited(exitCode))
        let identifier = try #require(first.simulatorIdentifier)
        #expect(second.simulatorIdentifier == identifier)
        let calls = try fixture.calls()
        #expect(calls.filter { $0.hasPrefix("create ") }.count == 1)
        #expect(!calls.contains { $0.hasPrefix("delete ") })
        for request in [
            "uninstall \(identifier) com.example.TestHost", "keychain \(identifier) reset",
            "privacy \(identifier) reset all", "status_bar \(identifier) clear", "location \(identifier) clear",
        ] {
            #expect(calls.filter { $0 == request }.count == 2, "\(request)")
        }
        #expect(!calls.contains { $0.hasPrefix("uninstall ") && $0.hasSuffix(" com.apple.mobilesafari") })
    }

    @Test func shutdownDestinationIsBootedForCleanupAndReused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = fixture.runner
        var request = fixture.request("first")
        request.environment["SHUTDOWN_AFTER_TEST"] = "1"

        let first = try await runner.run(.test, request: request)
        let identifier = try #require(first.simulatorIdentifier)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "booted-" + identifier).path))
        let second = try await runner.run(.test, request: fixture.request("second"))

        #expect(second.simulatorIdentifier == identifier)
    }

    @Test(arguments: [XcodeBuildAction.build, .buildForTesting])
    func buildOperationsDoNotRequireABootedDevice(action: XcodeBuildAction) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.root.appending(path: "fail-boot"))

        let result = try await fixture.runner.run(action, request: fixture.request("build"))

        #expect(result.succeeded)
        let calls = try fixture.calls()
        #expect(!calls.contains { $0.hasPrefix("bootstatus ") })
        #expect(!calls.contains { $0.hasPrefix("listapps ") })
    }

    @Test func unavailableRetainedDeviceIsRecreatedForBuild() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = fixture.runner
        let first = try await runner.run(.build, request: fixture.request("first"))
        let identifier = try #require(first.simulatorIdentifier)
        try Data().write(to: fixture.root.appending(path: "unavailable-" + identifier))

        let second = try await runner.run(.build, request: fixture.request("second"))

        #expect(second.simulatorIdentifier != identifier)
        let calls = try fixture.calls()
        #expect(calls.contains { $0.hasPrefix("delete " + identifier) })
        #expect(!calls.contains { $0.hasPrefix("bootstatus ") })
    }

    @Test func concurrentOperationsUseDifferentDevicesAndIdleCleanupSkipsActiveLeases() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = fixture.root.appending(path: "payload-gate")
        try Data().write(to: gate)
        let runner = fixture.runner
        var request = fixture.request("first")
        request.environment["PAYLOAD_GATE"] = gate.path
        let firstRequest = request
        let first = Task { try await runner.run(.test, request: firstRequest) }
        defer {
            try? FileManager.default.removeItem(at: gate)
            first.cancel()
        }
        try await waitForFile(fixture.root.appending(path: "started-first"))
        let second = try await runner.run(.test, request: fixture.request("second"))
        let activeIdentifier = try String(contentsOf: fixture.root.appending(path: "started-first"), encoding: .utf8)
        let idleIdentifier = try #require(second.simulatorIdentifier)
        try "renamed idle device".write(
            to: fixture.root.appending(path: "devices/" + idleIdentifier), atomically: true, encoding: .utf8
        )
        try await SimulatorPool(directory: fixture.poolDirectory).removeIdleSimulators(
            executableURL: fixture.root.appending(path: "simctl")
        )
        let callsAfterCleanup = try fixture.calls()
        #expect(callsAfterCleanup.contains { $0.hasPrefix("delete " + idleIdentifier) })
        #expect(!callsAfterCleanup.contains { $0.hasPrefix("delete " + activeIdentifier) })
        let remainingEntries = try FileManager.default.subpathsOfDirectory(atPath: fixture.poolDirectory.path)
            .filter { URL(filePath: $0).lastPathComponent.hasPrefix("device-") }
        let activeRecord = try #require(remainingEntries.first { $0.hasSuffix(".json") })
        let activeEntry = String(activeRecord.dropLast(".json".count))
        #expect(Set(remainingEntries) == Set([activeRecord, activeEntry + ".lock", activeEntry + ".processes.lock"]))
        try FileManager.default.removeItem(at: gate)
        let firstResult = try await first.value

        #expect(firstResult.simulatorIdentifier != second.simulatorIdentifier)
        #expect(try fixture.calls().filter { $0.hasPrefix("create ") }.count == 2)
    }

    @Test func backgroundBuildChildFinishesBeforeDeviceCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = fixture.root.appending(path: "lease-child-gate")
        let started = fixture.root.appending(path: "lease-child-started")
        try Data().write(to: gate)
        defer { try? FileManager.default.removeItem(at: gate) }
        let clock = Clock()
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        var runner = fixture.runner(clock: clock)
        runner.simulatorPool?.executionPool = pool
        let selectedRunner = runner
        var request = fixture.request("first")
        request.environment["LEASE_CHILD_GATE"] = gate.path
        request.environment["LEASE_CHILD_STARTED"] = started.path
        let firstRequest = request
        let first = Task { try await selectedRunner.run(.test, request: firstRequest) }
        defer { first.cancel() }

        try await waitForFile(started)
        let identifier = try String(contentsOf: fixture.root.appending(path: "started-first"), encoding: .utf8)
        clock.advance(by: 40 * 60)
        try await pool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try !fixture.calls().contains { $0.hasPrefix("delete " + identifier) })
        // The child still holds the first lease, so the next operation needs another device.
        let second = try await runner.run(.test, request: fixture.request("second"))
        #expect(second.simulatorIdentifier != identifier)

        try FileManager.default.removeItem(at: gate)
        let firstResult = try await first.value
        #expect(firstResult.simulatorIdentifier == identifier)
        // The fake tools record both events, so this order does not depend on when the test looked.
        let events = try fixture.events()
        let finished = try #require(events.firstIndex(of: "lease-child-finished"))
        let cleanup = try #require(events.firstIndex(of: "cleanup-started " + identifier))
        #expect(finished < cleanup)
    }

    @Test func deviceRemainsLeasedUntilCleanupFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock()
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        var runner = fixture.runner(clock: clock)
        runner.simulatorPool?.executionPool = pool
        let selectedRunner = runner
        var request = fixture.request("first")
        request.environment["BLOCK_CLEANUP"] = "1"
        let firstRequest = request
        let first = Task { try await selectedRunner.run(.test, request: firstRequest) }
        defer { first.cancel() }
        let started = fixture.root.appending(path: "started-first")
        try await waitForFile(started)
        let identifier = try String(contentsOf: started, encoding: .utf8)
        let gate = fixture.root.appending(path: "cleanup-gate-" + identifier)
        defer { try? FileManager.default.removeItem(at: gate) }
        try await waitForFile(fixture.root.appending(path: "cleanup-started-" + identifier))
        clock.advance(by: 40 * 60)
        try await pool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try !fixture.calls().contains { $0.hasPrefix("delete " + identifier) })

        let second = try await runner.run(.test, request: fixture.request("second"))
        #expect(second.simulatorIdentifier != identifier)
        try FileManager.default.removeItem(at: gate)
        let firstResult = try await first.value
        #expect(firstResult.simulatorIdentifier == identifier)
        clock.advance(by: 19 * 60)
        try await pool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try fixture.devices().count == 2)
        clock.advance(by: 60)
        try await pool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try fixture.devices().isEmpty)
    }

    @Test(arguments: [Int32(0), Int32(7)])
    func cleanupFailureRetiresTheDeviceAndPreservesTheOperationResult(exitCode: Int32) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.root.appending(path: "fail-cleanup"))
        let runner = fixture.runner
        do {
            _ = try await runner.run(.test, request: fixture.request("first", exitCode: exitCode))
            Issue.record("A Simulator cleanup failure returned successfully.")
        } catch let failure as XcodeBuildFailure {
            let result = try #require(failure.result)
            #expect(result.status == .exited(exitCode))
            #expect(FileManager.default.fileExists(atPath: result.logURL.path))
            #expect(failure.cleanupErrors.count == 1)
            let cleanup = try #require(failure.cleanupErrors.first as? SimulatorCleanupFailure)
            #expect(cleanup.simulatorIdentifier == result.simulatorIdentifier)
            #expect(cleanup.simulatorName.hasPrefix("XcodeRunnerKit-Pool-"))
            #expect(cleanup.underlyingError.localizedDescription.contains("cleanup-failed"))
        }
        let second = try await runner.run(.test, request: fixture.request("second"))
        let calls = try fixture.calls()
        let created = calls.filter { $0.hasPrefix("create ") }
        #expect(created.count == 2)
        #expect(calls.contains { $0.hasPrefix("delete ") && !$0.contains(second.simulatorIdentifier ?? "") })
    }

    @Test func cancellationRetiresTheDeviceBeforeTheNextOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = fixture.root.appending(path: "payload-gate")
        try Data().write(to: gate)
        let runner = fixture.runner
        var request = fixture.request("first")
        request.environment["PAYLOAD_GATE"] = gate.path
        let firstRequest = request
        let first = Task { try await runner.run(.test, request: firstRequest) }
        defer { first.cancel() }
        let started = fixture.root.appending(path: "started-first")
        try await waitForFile(started)
        let identifier = try String(contentsOf: started, encoding: .utf8)
        try "renamed active device".write(
            to: fixture.root.appending(path: "devices/" + identifier), atomically: true, encoding: .utf8
        )
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("A cancelled operation returned successfully.")
        } catch let failure as XcodeBuildFailure {
            #expect(failure.result?.status == .cancelled)
        }
        let remainingEntries = try FileManager.default.subpathsOfDirectory(atPath: fixture.poolDirectory.path)
            .filter { URL(filePath: $0).lastPathComponent.hasPrefix("device-") }
        #expect(remainingEntries.isEmpty)

        let second = try await runner.run(.test, request: fixture.request("second"))
        #expect(second.simulatorIdentifier != identifier)
        #expect(try fixture.calls().contains { $0.hasPrefix("delete " + identifier) })
    }

    @Test func abandonedDirtyDeviceIsDiscardedBeforeTheNextOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.runner.run(.test, request: fixture.request("first"))
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.poolDirectory.path)
        let record = try #require(files.first { URL(filePath: $0).lastPathComponent.hasPrefix("device-") && $0.hasSuffix(".json") })
        let recordURL = fixture.poolDirectory.appending(path: record)
        var contents = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        contents["isReady"] = false
        try JSONSerialization.data(withJSONObject: contents).write(to: recordURL, options: .atomic)

        let second = try await fixture.runner.run(.test, request: fixture.request("second"))
        #expect(second.simulatorIdentifier != first.simulatorIdentifier)
        #expect(try fixture.calls().contains { $0.hasPrefix("delete " + (first.simulatorIdentifier ?? "")) })
    }

    @Test func simulatorChildInheritsTheExplicitLeaseDescriptor() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let leaseURL = fixture.root.appending(path: "lease-marker")
        try Data("lease marker".utf8).write(to: leaseURL)
        let descriptor = Darwin.open(leaseURL.path, O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { _ = Darwin.close(descriptor) }
        let inherited = fixture.root.appending(path: "descriptor-inherited")
        let executable = fixture.root.appending(path: "simctl-with-lease")
        try """
            #!/bin/sh
            [ "$(/bin/cat /dev/fd/\(descriptor))" = 'lease marker' ] || exit 9
            touch '\(inherited.path)'
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var tool = SimulatorTool(executableURL: executable)
        tool.inheritedLeaseDescriptor = descriptor

        try await tool.boot("unused-device")

        #expect(FileManager.default.fileExists(atPath: inherited.path))
    }

    @Test func savedLimitBoundsRetainedDevicesAcrossConfigurationsAndXcodes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        try await pool.updateMaximumConcurrentJobs(to: 2, executableURL: fixture.root.appending(path: "simctl"))
        var runner = fixture.runner
        runner.executionPool = pool

        let first = try await runner.run(.test, request: fixture.request("first"))
        let reused = try await runner.run(.test, request: fixture.request("reused"))
        #expect(reused.simulatorIdentifier == first.simulatorIdentifier)
        for (index, configuration) in [
            SimulatorConfiguration(runtimeIdentifier: "other-runtime", deviceTypeIdentifier: "device"),
            SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "other-device"),
            SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device"),
        ].enumerated() {
            if index == 2 { runner.developerDirectory = fixture.root.appending(path: "OtherXcode") }
            var request = fixture.request("configuration-\(index)")
            request.destination = .managedSimulator(configuration)
            _ = try await runner.run(.test, request: request)
            #expect(try fixture.devices().count == 2)
        }
        #expect(try fixture.calls().filter { $0.hasPrefix("create ") }.count == 4)
    }

    @Test func concurrentReservationsShareTheSavedSimulatorLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        try await pool.updateMaximumConcurrentJobs(to: 2, executableURL: fixture.root.appending(path: "simctl"))
        try Data("2".utf8).write(to: fixture.root.appending(path: "device-limit"))
        let gate = fixture.root.appending(path: "payload-gate")
        try Data().write(to: gate)
        defer { try? FileManager.default.removeItem(at: gate) }
        var runner = fixture.runner
        runner.simulatorPool = pool.simulatorPool
        let selectedRunner = runner
        let operation = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    var request = fixture.request("concurrent-\(index)")
                    request.environment["PAYLOAD_GATE"] = gate.path
                    let selectedRequest = request
                    group.addTask { _ = try await selectedRunner.run(.test, request: selectedRequest) }
                }
                try await group.waitForAll()
            }
        }
        defer { operation.cancel() }
        try await waitUntil {
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                .filter { $0.hasPrefix("started-concurrent-") }.count >= 2
        }
        try FileManager.default.removeItem(at: gate)
        try await operation.value

        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "exceeded-device-limit").path))
        #expect(try fixture.devices().count == 2)
    }

    @Test func loweringTheLimitPreservesActiveDevicesAndTrimsAfterTheyFinish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        let simctl = fixture.root.appending(path: "simctl")
        try await pool.updateMaximumConcurrentJobs(to: 3, executableURL: simctl)
        var runner = fixture.runner
        runner.executionPool = pool
        runner.simulatorPool = nil
        let selectedRunner = runner
        let gate = fixture.root.appending(path: "payload-gate")
        try Data().write(to: gate)
        defer { try? FileManager.default.removeItem(at: gate) }
        let operations = (0..<3).map { index in
            var request = fixture.request("active-\(index)")
            request.environment["PAYLOAD_GATE"] = gate.path
            request.destination = .managedSimulator(SimulatorConfiguration(
                runtimeIdentifier: "runtime-\(index)", deviceTypeIdentifier: "device"
            ))
            let selectedRequest = request
            return Task { try await selectedRunner.run(.test, request: selectedRequest) }
        }
        defer { operations.forEach { $0.cancel() } }
        for index in 0..<3 { try await waitForFile(fixture.root.appending(path: "started-active-\(index)")) }

        try await pool.updateMaximumConcurrentJobs(to: 1, executableURL: simctl)

        #expect(try await pool.status()?.maximumConcurrentJobs == 1)
        #expect(try fixture.devices().count == 3)
        #expect(try !fixture.calls().contains { $0.hasPrefix("delete ") })
        try FileManager.default.removeItem(at: gate)
        for operation in operations { #expect(try await operation.value.succeeded) }
        #expect(try fixture.devices().count == 1)
    }

    @Test func freshDevicesReplaceIdleDevicesWithinTheSavedLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        try await pool.updateMaximumConcurrentJobs(to: 1, executableURL: fixture.root.appending(path: "simctl"))
        try Data("1".utf8).write(to: fixture.root.appending(path: "device-limit"))
        var runner = fixture.runner
        runner.executionPool = pool
        runner.simulatorPool = nil
        let retained = try await runner.run(.test, request: fixture.request("retained"))
        var request = fixture.request("fresh")
        var configuration = SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device")
        configuration.reusesDevice = false
        request.destination = .managedSimulator(configuration)

        let fresh = try await runner.run(.test, request: request)

        #expect(fresh.simulatorIdentifier != retained.simulatorIdentifier)
        #expect(try fixture.devices().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "exceeded-device-limit").path))
    }

    @Test func configurationFailureReportsTheSavedLimitAndAllowsCleanupRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        let simctl = fixture.root.appending(path: "simctl")
        var runner = fixture.runner
        runner.simulatorPool = pool.simulatorPool
        for index in 0..<3 {
            var request = fixture.request("retained-\(index)")
            request.destination = .managedSimulator(SimulatorConfiguration(
                runtimeIdentifier: "runtime-\(index)", deviceTypeIdentifier: "device"
            ))
            _ = try await runner.run(.test, request: request)
        }
        try Data().write(to: fixture.root.appending(path: "fail-delete"))

        do {
            try await pool.updateMaximumConcurrentJobs(to: 1, executableURL: simctl)
            Issue.record("Configuring the limit hid a Simulator deletion failure.")
        } catch let failure as HostExecutionPool.ConfigurationCleanupFailure {
            #expect(failure.savedMaximumConcurrentJobs == 1)
            #expect(failure.underlyingError.localizedDescription.contains("delete-failed"))
        }
        #expect(try await pool.status()?.maximumConcurrentJobs == 1)
        #expect(try fixture.devices().count == 3)

        try FileManager.default.removeItem(at: fixture.root.appending(path: "fail-delete"))
        try await pool.removeExcessSimulators(executableURL: simctl)
        #expect(try fixture.devices().count == 1)
    }

    @Test func obsoleteXcodeDoesNotPreventReplacingAnIdleDevice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        try await pool.updateMaximumConcurrentJobs(to: 1, executableURL: fixture.root.appending(path: "simctl"))
        let oldXcode = fixture.root.appending(path: "OldXcode")
        let currentXcode = fixture.root.appending(path: "CurrentXcode")
        for directory in [oldXcode, currentXcode] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: fixture.root.appending(path: "require-valid-xcode"))
        var runner = fixture.runner
        runner.executionPool = pool
        runner.simulatorPool = nil
        runner.developerDirectory = oldXcode
        let old = try await runner.run(.test, request: fixture.request("old-xcode"))
        try FileManager.default.removeItem(at: oldXcode)
        runner.developerDirectory = currentXcode

        let current = try await runner.run(.test, request: fixture.request("current-xcode"))

        #expect(current.simulatorIdentifier != old.simulatorIdentifier)
        let currentIdentifier = try #require(current.simulatorIdentifier)
        #expect(try fixture.devices() == [currentIdentifier])
    }

    @Test func loweringTheLimitImmediatelyTrimsACustomRegistry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        let simctl = fixture.root.appending(path: "simctl")
        try await pool.updateMaximumConcurrentJobs(to: 3, executableURL: simctl)
        var runner = fixture.runner
        runner.executionPool = pool
        for index in 0..<3 {
            var request = fixture.request("custom-\(index)")
            request.destination = .managedSimulator(SimulatorConfiguration(
                runtimeIdentifier: "runtime-\(index)", deviceTypeIdentifier: "device"
            ))
            _ = try await runner.run(.test, request: request)
        }
        #expect(try fixture.devices().count == 3)

        try await pool.updateMaximumConcurrentJobs(to: 1, executableURL: simctl)

        #expect(try fixture.devices().count == 1)
    }

    @Test func defaultAndCustomRegistriesShareOneDeviceLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        try await pool.updateMaximumConcurrentJobs(to: 1, executableURL: fixture.root.appending(path: "simctl"))
        try Data("1".utf8).write(to: fixture.root.appending(path: "device-limit"))
        var runner = fixture.runner
        runner.executionPool = pool
        runner.simulatorPool = nil
        let standard = try await runner.run(.test, request: fixture.request("default-registry"))
        runner.simulatorPool = SimulatorPool(directory: fixture.poolDirectory)

        let custom = try await runner.run(.test, request: fixture.request("custom-registry"))

        #expect(custom.simulatorIdentifier != standard.simulatorIdentifier)
        let customIdentifier = try #require(custom.simulatorIdentifier)
        #expect(try fixture.devices() == [customIdentifier])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "exceeded-device-limit").path))
    }

    @Test func eachReturnRenewsTheTwentyMinuteIdlePeriod() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock()
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        var runner = fixture.runner(clock: clock)
        runner.simulatorPool?.executionPool = pool
        let first = try await runner.run(.test, request: fixture.request("first"))

        clock.advance(by: 19 * 60)
        let second = try await runner.run(.test, request: fixture.request("second"))
        clock.advance(by: 19 * 60)
        let third = try await runner.run(.test, request: fixture.request("third"))

        #expect(second.simulatorIdentifier == first.simulatorIdentifier)
        #expect(third.simulatorIdentifier == first.simulatorIdentifier)
        clock.advance(by: 20 * 60)
        try await pool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try fixture.devices().isEmpty)
    }

    @Test func expiredDevicesAreReplacedBeforeReuse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock()
        let runner = fixture.runner(clock: clock)
        let first = try await runner.run(.test, request: fixture.request("first"))

        clock.advance(by: 20 * 60)
        let second = try await runner.run(.test, request: fixture.request("second"))

        #expect(second.simulatorIdentifier != first.simulatorIdentifier)
        let identifier = try #require(second.simulatorIdentifier)
        #expect(try fixture.devices() == [identifier])
    }

    @Test func changedRetentionAppliesToExistingIdleDevicesAndPersistsAcrossPoolInstances() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock()
        let directory = fixture.root.appending(path: "execution")
        let pool = HostExecutionPool(directory: directory)
        #expect(try pool.simulatorIdleRetentionMinutes() == 20)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try await pool.updateSimulatorIdleRetentionMinutes(to: 5)
        let reopenedPool = HostExecutionPool(directory: directory)
        #expect(try reopenedPool.simulatorIdleRetentionMinutes() == 5)
        var runner = fixture.runner(clock: clock)
        runner.simulatorPool?.executionPool = reopenedPool
        _ = try await runner.run(.test, request: fixture.request("retained"))

        clock.advance(by: 4 * 60)
        try await pool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try fixture.devices().count == 1)
        try await pool.updateSimulatorIdleRetentionMinutes(to: 10)
        clock.advance(by: 2 * 60)
        try await reopenedPool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try fixture.devices().count == 1)

        try await pool.updateSimulatorIdleRetentionMinutes(to: 5)
        try await reopenedPool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try fixture.devices().isEmpty)
    }

    @Test func acquisitionReadsAnUpdatedRetentionSetting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock()
        let directory = fixture.root.appending(path: "execution")
        var runner = fixture.runner(clock: clock)
        runner.simulatorPool?.executionPool = HostExecutionPool(directory: directory)
        let first = try await runner.run(.test, request: fixture.request("first"))
        try await HostExecutionPool(directory: directory).updateSimulatorIdleRetentionMinutes(to: 5)

        clock.advance(by: 5 * 60)
        let second = try await runner.run(.test, request: fixture.request("second"))

        #expect(second.simulatorIdentifier != first.simulatorIdentifier)
        let identifier = try #require(second.simulatorIdentifier)
        #expect(try fixture.devices() == [identifier])
    }

    @Test func newestReturnedDeviceIsReusedAndOldestIdleDeviceIsEvictedAcrossRegistries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock()
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        try await pool.updateMaximumConcurrentJobs(to: 2, executableURL: fixture.root.appending(path: "simctl"))
        var runner = fixture.runner(clock: clock)
        runner.executionPool = pool
        let selectedRunner = runner
        let gate = fixture.root.appending(path: "payload-gate")
        try Data().write(to: gate)
        defer { try? FileManager.default.removeItem(at: gate) }
        var request = fixture.request("first")
        request.environment["PAYLOAD_GATE"] = gate.path
        let firstRequest = request
        let first = Task { try await selectedRunner.run(.test, request: firstRequest) }
        defer { first.cancel() }
        try await waitForFile(fixture.root.appending(path: "started-first"))
        let older = try await runner.run(.test, request: fixture.request("second"))
        clock.advance(by: 60)
        try FileManager.default.removeItem(at: gate)
        let newer = try await first.value

        clock.advance(by: 60)
        let reused = try await runner.run(.test, request: fixture.request("reused"))
        #expect(reused.simulatorIdentifier == newer.simulatorIdentifier)
        runner.simulatorPool = pool.simulatorPool
        runner.simulatorPool?.now = { clock.now }
        var otherRequest = fixture.request("other")
        otherRequest.destination = .managedSimulator(SimulatorConfiguration(
            runtimeIdentifier: "other-runtime", deviceTypeIdentifier: "device"
        ))
        let other = try await runner.run(.test, request: otherRequest)

        #expect(try Set(fixture.devices()) == Set([
            try #require(newer.simulatorIdentifier), try #require(other.simulatorIdentifier),
        ]))
        #expect(try fixture.calls().contains { $0.hasPrefix("delete " + (older.simulatorIdentifier ?? "")) })
    }

    @Test func legacyRecordsExpireUsingTheirModificationDate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = Clock()
        let pool = HostExecutionPool(directory: fixture.root.appending(path: "execution"))
        var runner = fixture.runner(clock: clock)
        runner.simulatorPool?.executionPool = pool
        _ = try await runner.run(.test, request: fixture.request("legacy"))
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.poolDirectory.path)
        let record = try #require(files.first {
            URL(filePath: $0).lastPathComponent.hasPrefix("device-") && $0.hasSuffix(".json")
        })
        let recordURL = fixture.poolDirectory.appending(path: record)
        var contents = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        contents.removeValue(forKey: "returnedAt")
        try JSONSerialization.data(withJSONObject: contents).write(to: recordURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: recordURL.path)

        clock.advance(by: 19 * 60)
        try await pool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try fixture.devices().count == 1)
        clock.advance(by: 60)
        try await pool.removeExcessSimulators(executableURL: fixture.root.appending(path: "simctl"), now: clock.now)
        #expect(try fixture.devices().isEmpty)
    }

    private func completedResult(_ runner: XcodeRunner, request: XcodeBuildRequest) async throws -> XcodeBuildResult {
        do { return try await runner.run(.test, request: request) }
        catch let failure as XcodeBuildFailure { return try #require(failure.result) }
    }

    private func waitForFile(_ url: URL) async throws {
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) }
    }

    private final class Clock: Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 2_000_000_000))
        var now: Date { value.withLock { $0 } }
        func advance(by interval: TimeInterval) { value.withLock { $0 += interval } }
    }

    private struct Fixture: Sendable {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        var poolDirectory: URL { root.appending(path: "pool") }

        init() throws {
            try FileManager.default.createDirectory(at: root.appending(path: "devices"), withIntermediateDirectories: true)
            try writeScript("""
                root='\(root.path)'
                (shift; printf '%s\\n' "$*") >> "$root/calls"
                if [ -e "$root/require-valid-xcode" ] && [ -n "$DEVELOPER_DIR" ] && [ ! -d "$DEVELOPER_DIR" ]; then
                    echo invalid-developer-directory >&2
                    exit 9
                fi
                case "$2" in
                create)
                    identifier=$(/usr/bin/uuidgen)
                    printf '%s' "$3" > "$root/devices/$identifier"
                    if [ -f "$root/device-limit" ]; then
                        set -- "$root/devices/"*
                        if [ "$#" -gt "$(cat "$root/device-limit")" ]; then touch "$root/exceeded-device-limit"; fi
                    fi
                    printf '%s\\n' "$identifier";;
                list)
                    printf '{"devices":{"runtime":['
                    separator=''
                    for device in "$root/devices/"*; do
                        [ -f "$device" ] || continue
                        identifier=${device##*/}
                        name=$(cat "$device")
                        available=true
                        if [ -e "$root/unavailable-$identifier" ]; then available=false; fi
                        printf '%s{"udid":"%s","name":"%s","state":"Booted","isAvailable":%s}' "$separator" "$identifier" "$name" "$available"
                        separator=','
                    done
                    printf ']}}\\n';;
                listapps)
                    if [ -e "$root/fail-cleanup" ]; then
                        rm "$root/fail-cleanup"
                        echo cleanup-failed >&2
                        exit 9
                    fi
                    if [ ! -e "$root/booted-$3" ]; then
                        echo 'device is Shutdown (405)' >&2
                        exit 405
                    fi
                    touch "$root/cleanup-started-$3"
                    printf 'cleanup-started %s\\n' "$3" >> "$root/events"
                    while [ -e "$root/cleanup-gate-$3" ]; do sleep 0.02; done
                    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>com.example.TestHost</key><dict><key>ApplicationType</key><string>User</string></dict><key>com.apple.mobilesafari</key><dict><key>ApplicationType</key><string>System</string></dict></dict></plist>\\n';;
                bootstatus)
                    if [ -e "$root/fail-boot" ]; then echo boot-failed >&2; exit 9; fi
                    touch "$root/booted-$3";;
                delete)
                    if [ -e "$root/fail-delete" ]; then echo delete-failed >&2; exit 9; fi
                    rm -f "$root/devices/$3" "$root/booted-$3";;
                esac
                """, to: root.appending(path: "simctl"))
            try writeScript("""
                action="$1"
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = '-destination' ]; then
                        destination="$2"
                        break
                    fi
                    shift
                done
                identifier=${destination##*id=}
                case "$action" in
                test|test-without-building) [ -e "$FIXTURE_ROOT/booted-$identifier" ] || exit 9;;
                esac
                if [ "$BLOCK_CLEANUP" = '1' ]; then touch "$FIXTURE_ROOT/cleanup-gate-$identifier"; fi
                printf '%s' "$identifier" > "$STARTED_PATH"
                while [ -n "$PAYLOAD_GATE" ] && [ -e "$PAYLOAD_GATE" ]; do sleep 0.02; done
                if [ -n "$LEASE_CHILD_GATE" ]; then
                    (
                        touch "$LEASE_CHILD_STARTED"
                        while [ -e "$LEASE_CHILD_GATE" ]; do sleep 0.02; done
                        printf 'lease-child-finished\\n' >> "$FIXTURE_ROOT/events"
                    ) </dev/null >/dev/null 2>&1 &
                fi
                if [ "$SHUTDOWN_AFTER_TEST" = '1' ] && [ "$EXIT_CODE" = '0' ]; then
                    case "$action" in
                    test|test-without-building) rm "$FIXTURE_ROOT/booted-$identifier";;
                    esac
                fi
                exit "$EXIT_CODE"
                """, to: root.appending(path: "xcodebuild"))
        }

        var runner: XcodeRunner {
            var runner = XcodeRunner(
                executableURL: root.appending(path: "xcodebuild"),
                developerDirectory: root.appending(path: "Xcode"),
                simulatorExecutableURL: root.appending(path: "simctl")
            )
            runner.simulatorPool = SimulatorPool(directory: poolDirectory)
            return runner
        }

        func runner(clock: Clock) -> XcodeRunner {
            var runner = self.runner
            runner.simulatorPool?.now = { clock.now }
            return runner
        }

        func request(_ name: String, exitCode: Int32 = 0) -> XcodeBuildRequest {
            var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
            request.destination = .managedSimulator(SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device"))
            request.environment = [
                "FIXTURE_ROOT": root.path,
                "STARTED_PATH": root.appending(path: "started-" + name).path,
                "EXIT_CODE": String(exitCode),
            ]
            return request
        }

        func events() throws -> [String] {
            try String(contentsOf: root.appending(path: "events"), encoding: .utf8).split(separator: "\n").map(String.init)
        }

        func calls() throws -> [String] {
            try String(contentsOf: root.appending(path: "calls"), encoding: .utf8).split(separator: "\n").map(String.init)
        }

        func devices() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "devices").path)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private func writeScript(_ body: String, to url: URL) throws {
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
}
