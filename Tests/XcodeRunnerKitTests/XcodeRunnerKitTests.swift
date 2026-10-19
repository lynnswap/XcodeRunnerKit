import Darwin
import Foundation
import Testing
@testable import XcodeRunnerKit

struct XcodeRunnerKitTests {
    @Test func runnerPassesOperationPriorityToTheSharedPool() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try HostExecutionPool(directory: root.appending(path: "pool"), initialCapacity: 1)
        let executable = try script("touch \"$STARTED_PATH\"; while [ ! -e \"$RELEASE_PATH\" ]; do sleep 0.02; done", at: root)
        var configuredRunner = XcodeRunner(executableURL: executable)
        configuredRunner.executionPool = pool
        let runner = configuredRunner
        var configuredLow = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "low-output"))
        configuredLow.environment = [
            "STARTED_PATH": root.appending(path: "low-started").path,
            "RELEASE_PATH": root.appending(path: "low-release").path,
        ]
        let low = configuredLow
        var configuredHigh = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "high-output"))
        configuredHigh.environment = [
            "STARTED_PATH": root.appending(path: "high-started").path,
            "RELEASE_PATH": root.appending(path: "high-release").path,
        ]
        let high = configuredHigh
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await pool.withSlot {
                    try Data().write(to: root.appending(path: "blocker-started"))
                    while !FileManager.default.fileExists(atPath: root.appending(path: "blocker-release").path) {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
            try await waitForFile(root.appending(path: "blocker-started"))
            group.addTask { _ = try await runner.run(.build, request: low, priority: .low) }
            try await waitForWaitingCount(1, at: .low, in: pool)
            group.addTask { _ = try await runner.run(.build, request: high, priority: .high) }
            try await waitForWaitingCount(1, at: .high, in: pool)
            try Data().write(to: root.appending(path: "blocker-release"))
            try await waitForFile(root.appending(path: "high-started"))
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "low-started").path))
            try Data().write(to: root.appending(path: "high-release"))
            try await waitForFile(root.appending(path: "low-started"))
            try Data().write(to: root.appending(path: "low-release"))
            try await group.waitForAll()
        }
        let status = try #require(try await pool.status())
        #expect(status.activeJobCount == 0)
        #expect(status.waitingJobCounts.total == 0)
        #expect(HostExecutionPool.Priority.allCases.allSatisfy { status.waitingJobCounts[$0] == 0 })
    }

    @Test func capturesOutputAndPreservesArgumentsWithSpaces() async throws {
        let root = URL.temporaryDirectory.appending(path: "Runner tests " + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script("printf '%s\\n' \"$@\"; printf 'stderr marker\\n' >&2; printf '%s\\n' \"$TEST_VALUE\"", at: root)
        var request = XcodeBuildRequest(
            source: .package(root), scheme: "Scheme with spaces", outputDirectory: root.appending(path: "output")
        )
        request.environment["TEST_VALUE"] = "environment value"
        let result = try await XcodeRunner(executableURL: executable).run(.build, request: request)
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        #expect(result.succeeded)
        #expect(log.contains("Scheme with spaces\n"))
        #expect(log.contains(root.path(percentEncoded: false)))
        #expect(log.contains("stderr marker"))
        #expect(log.contains("environment value"))
    }

    @Test(arguments: [false, true])
    func explicitBuildServiceOverridesEnvironmentWhenConfigured(_ isConfigured: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: "Build service " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script("printf '%s\\n' \"$SWBBUILDSERVICE_PATH\" \"$XCBBUILDSERVICE_PATH\"", at: root)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root)
        request.environment = [
            "SWBBUILDSERVICE_PATH": "/existing/service",
            "XCBBUILDSERVICE_PATH": "/existing/legacy-service",
        ]
        var runner = XcodeRunner(executableURL: executable)
        let customService = root.appending(path: "Custom service.bundle/SWBBuildServiceBundle")
        if isConfigured { runner.buildServiceExecutableURL = customService }

        let result = try await runner.run(.build, request: request)
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        let expectedService = isConfigured ? customService.path(percentEncoded: false) : "/existing/service"
        #expect(log == expectedService + "\n/existing/legacy-service\n")
    }

    @Test func nonzeroExitRetainsStatusAndDiagnostics() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script("printf 'build failure\\n' >&2; exit 7", at: root)
        let request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root)
        do {
            _ = try await XcodeRunner(executableURL: executable).run(.test, request: request)
            Issue.record("A failing tool returned successfully.")
        } catch let error as XcodeBuildFailure {
            #expect(error.result.status == .exited(7))
            #expect(try String(contentsOf: error.result.logURL, encoding: .utf8).contains("build failure"))
        }
    }

    @Test func missingExecutablePreservesTheUnderlyingError() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root)
        do {
            _ = try await XcodeRunner(executableURL: root.appending(path: "missing")).run(.build, request: request)
            Issue.record("A missing executable returned successfully.")
        } catch let error as XcodeBuildFailure {
            #expect(error.result.status == .executionFailed)
            #expect(error.underlyingError != nil)
            #expect(FileManager.default.fileExists(atPath: error.result.logURL.path(percentEncoded: false)))
        }
    }

    @Test func cancellationTerminatesTheProcessGroup() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appending(path: "ready")
        let executable = try script("sleep 120 &\nchild=$!\nprintf '%s %s\\n' \"$$\" \"$child\" > \"$READY_PATH.tmp\"\nmv \"$READY_PATH.tmp\" \"$READY_PATH\"\nwait \"$child\"", at: root)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root)
        request.environment["READY_PATH"] = marker.path(percentEncoded: false)
        var runner = XcodeRunner(executableURL: executable)
        runner.executionPool = try HostExecutionPool(directory: root.appending(path: "pool"), initialCapacity: 1)
        let configuredRunner = runner
        let task = Task { try await configuredRunner.run(.test, request: request) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The tool did not become ready.")
            return
        }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        #expect(pids.count == 2)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation returned successfully.")
        } catch let error as XcodeBuildFailure {
            #expect(error.result.status == .cancelled)
        }
        let pool = try #require(configuredRunner.executionPool)
        try await pool.withSlot {}
        for pid in pids {
            let reapingDeadline = clock.now.advanced(by: .seconds(10))
            while kill(pid, 0) == 0 && clock.now < reapingDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(kill(pid, 0) == -1, "Process \(pid) remained after cancellation.")
        }
    }

    @Test func poolAcquisitionFailureDoesNotExecutePayload() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appending(path: "pool")
        try Data().write(to: blocked)
        let marker = root.appending(path: "unexpected-payload")
        let pool = try HostExecutionPool(directory: blocked, initialCapacity: 2)
        do {
            try await pool.withSlot { try Data().write(to: marker) }
            Issue.record("A pool I/O failure bypassed the limit.")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test(arguments: [Int32(0), Int32(7)])
    func simulatorIsDeletedAfterSuccessOrFailure(exitCode: Int32) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = UUID().uuidString
        let simulator = root.appending(path: "simctl")
        let deleted = root.appending(path: "deleted")
        let booted = root.appending(path: "booted")
        let selectedXcode = root.appending(path: "selected-xcode")
        try """
            #!/bin/sh
            case "$2" in
            create) echo \(identifier); printf '%s' "$DEVELOPER_DIR" > \(selectedXcode.path);;
            bootstatus)
                [ "$3" = "\(identifier)" ] && [ "$4" = "-b" ] || exit 9
                touch \(booted.path);;
            delete) printf '%s' "$3" > \(deleted.path);;
            esac
            """.write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("[ -e \(booted.path) ] || exit 9; printf '%s\\n' \"$@\"; exit \(exitCode)", at: root)
        var runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        runner.executionPool = try HostExecutionPool(directory: root.appending(path: "pool"), initialCapacity: 1)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.simulator = SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device")
        request.simulator?.reusesDevice = false
        request.arguments = ["-parallel-testing-enabled", "NO"]
        request.environment["DEVELOPER_DIR"] = root.appending(path: "SelectedXcode").path
        let result: XcodeBuildResult
        do { result = try await runner.run(.test, request: request) }
        catch let failure as XcodeBuildFailure { result = failure.result }
        #expect(result.status == .exited(exitCode))
        #expect(result.simulatorIdentifier == identifier)
        #expect(try String(contentsOf: deleted, encoding: .utf8) == identifier)
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        #expect(log.contains("platform=iOS Simulator,id=" + identifier))
        #expect(log.components(separatedBy: "-parallel-testing-enabled").count == 2)
        #expect(try String(contentsOf: selectedXcode, encoding: .utf8) == request.environment["DEVELOPER_DIR"])
    }

    @Test func simulatorBootFailureSkipsPayloadAndDeletesTheOwnedDevice() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = UUID().uuidString
        let simulator = root.appending(path: "simctl")
        let deleted = root.appending(path: "deleted")
        let started = root.appending(path: "unexpected-payload")
        try """
            #!/bin/sh
            case "$2" in
            create) echo \(identifier);;
            bootstatus) echo boot-failed >&2; exit 9;;
            delete) printf '%s' "$3" > \(deleted.path);;
            esac
            """.write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("touch \(started.path)", at: root)
        let runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.simulator = SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device")
        request.simulator?.reusesDevice = false
        do {
            _ = try await runner.run(.testWithoutBuilding, request: request)
            Issue.record("Simulator boot failure returned successfully.")
        } catch {
            #expect((error as NSError).domain == "XcodeRunnerKit.simctl")
            #expect(error.localizedDescription.contains("boot-failed"))
        }
        #expect(!FileManager.default.fileExists(atPath: started.path))
        #expect(try String(contentsOf: deleted, encoding: .utf8) == identifier)
    }

    @Test func simulatorCleanupFailurePreservesBuildFailure() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = UUID().uuidString
        let simulator = root.appending(path: "simctl")
        try ("#!/bin/sh\ncase \"$2\" in\ncreate) echo " + identifier + ";;\ndelete) echo deletion-failed >&2; exit 9;;\nesac\n")
            .write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("exit 7", at: root)
        let runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root)
        request.simulator = SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device")
        request.simulator?.reusesDevice = false
        do {
            _ = try await runner.run(.test, request: request)
            Issue.record("Cleanup failure returned successfully.")
        } catch let failure as SimulatorCleanupFailure {
            #expect(failure.simulatorIdentifier == identifier)
            #expect((failure.operationError as? XcodeBuildFailure)?.result.status == .exited(7))
            #expect(failure.cleanupError.localizedDescription.contains("deletion-failed"))
        }
    }

    @Test func cancellationDuringCreationStillDeletesTheOwnedDevice() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = UUID().uuidString
        let ready = root.appending(path: "creating")
        let deleted = root.appending(path: "deleted")
        let simulator = root.appending(path: "simctl")
        try ("#!/bin/sh\ncase \"$2\" in\ncreate) touch " + ready.path + "; sleep 1; echo " + identifier + ";;\ndelete) touch " + deleted.path + ";;\nesac\n")
            .write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let runner = XcodeRunner(executableURL: root.appending(path: "must-not-start"), simulatorExecutableURL: simulator)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.simulator = SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device")
        request.simulator?.reusesDevice = false
        let configured = request
        let task = Task { try await runner.run(.test, request: configured) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: ready.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled Simulator creation returned successfully.")
        } catch is CancellationError {}
        #expect(FileManager.default.fileExists(atPath: deleted.path))
        #expect(!FileManager.default.fileExists(atPath: request.outputDirectory.path))
    }

    @Test(arguments: [Int32(0), Int32(7)])
    func cancellationDuringDeletionPreservesDiagnostics(exitCode: Int32) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = UUID().uuidString
        let ready = root.appending(path: "deleting")
        let finish = root.appending(path: "finish")
        let deleted = root.appending(path: "deleted")
        let simulator = root.appending(path: "simctl")
        try """
            #!/bin/sh
            case "$2" in
            create) echo \(identifier);;
            delete)
                touch \(ready.path)
                while [ ! -e \(finish.path) ]; do sleep 0.02; done
                touch \(deleted.path);;
            esac
            """.write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("printf 'completed payload\\n'; exit \(exitCode)", at: root)
        var runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        runner.executionPool = try HostExecutionPool(directory: root.appending(path: "pool"), initialCapacity: 1)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.simulator = SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device")
        request.simulator?.reusesDevice = false
        let configuredRunner = runner
        let configuredRequest = request
        let task = Task { try await configuredRunner.run(.test, request: configuredRequest) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: ready.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            task.cancel()
            try Data().write(to: finish)
            _ = try? await task.value
            Issue.record("Simulator deletion did not become ready.")
            return
        }
        task.cancel()
        try Data().write(to: finish)
        do {
            _ = try await task.value
            Issue.record("Cancellation during Simulator deletion returned successfully.")
        } catch let failure as XcodeBuildFailure {
            #expect(failure.result.status == (exitCode == 0 ? .cancelled : .exited(exitCode)))
            #expect(failure.result.simulatorIdentifier == identifier)
            #expect(try String(contentsOf: failure.result.logURL, encoding: .utf8).contains("completed payload"))
        }
        #expect(FileManager.default.fileExists(atPath: deleted.path))
        let pool = try #require(configuredRunner.executionPool)
        try await pool.withSlot {}
    }

    private func script(_ body: String, at root: URL) throws -> URL {
        let url = root.appending(path: "tool")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    private func waitForFile(_ url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: url.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: url.path), "The tool did not become ready.")
    }

    private func waitForWaitingCount(_ count: Int, at priority: HostExecutionPool.Priority, in pool: HostExecutionPool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while try await pool.status()?.waitingJobCounts[priority] != count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(try await pool.status()?.waitingJobCounts[priority] == count)
    }
}
