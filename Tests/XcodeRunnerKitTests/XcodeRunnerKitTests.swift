import Darwin
import Foundation
import Testing
@testable import XcodeRunnerKit

@Suite(.timeLimit(.minutes(1)))
struct XcodeRunnerKitTests {
    @Test func runnerPassesOperationPriorityToTheSharedPool() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try await Self.pool(at: root, maximumConcurrentJobs: 1)
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
            let result = try #require(error.result)
            #expect(result.status == .exited(7))
            #expect(error.underlyingError == nil)
            #expect(error.cleanupErrors.isEmpty)
            #expect(try String(contentsOf: result.logURL, encoding: .utf8).contains("build failure"))
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
            let result = try #require(error.result)
            #expect(result.status == .executionFailed)
            #expect(error.underlyingError != nil)
            #expect(FileManager.default.fileExists(atPath: result.logURL.path(percentEncoded: false)))
        }
    }

    @Test(arguments: [false, true])
    func missingParentFailsWithoutCreatingFolders(cacheOnly: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A storage folder on an unmounted volume looks like a missing parent.
        let unavailable = root.appending(path: "Unmounted volume")
        let marker = root.appending(path: "unexpected-payload")
        let executable = try script("touch \(marker.path)", at: root)
        var request = XcodeBuildRequest(
            source: .package(root), scheme: "Probe",
            outputDirectory: cacheOnly ? root.appending(path: "output") : unavailable.appending(path: "Build")
        )
        if cacheOnly { request.compilationCache = CompilationCache(directory: unavailable.appending(path: "CompilationCache")) }
        do {
            _ = try await XcodeRunner(executableURL: executable).run(.build, request: request)
            Issue.record("A missing storage folder returned successfully.")
        } catch let failure as XcodeBuildFailure {
            #expect(failure.underlyingError != nil)
        }
        #expect(!FileManager.default.fileExists(atPath: unavailable.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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
        runner.executionPool = try await Self.pool(at: root, maximumConcurrentJobs: 1)
        let configuredRunner = runner
        let task = Task { try await configuredRunner.run(.test, request: request) }
        defer { task.cancel() }
        try await waitForFile(marker)
        let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        #expect(pids.count == 2)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation returned successfully.")
        } catch let error as XcodeBuildFailure {
            #expect(error.result?.status == .cancelled)
        }
        let pool = try #require(configuredRunner.executionPool)
        try await pool.withSlot {}
        // A surviving process keeps this wait running until the suite time limit fails the test.
        for pid in pids {
            try await waitUntil { kill(pid, 0) == -1 }
        }
    }

    @Test func poolAcquisitionFailureDoesNotExecutePayload() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appending(path: "pool")
        try Data().write(to: blocked)
        let marker = root.appending(path: "unexpected-payload")
        let pool = HostExecutionPool(directory: blocked)
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
            create) touch \(root.appending(path: "created").path); echo \(identifier); printf '%s' "$DEVELOPER_DIR" > \(selectedXcode.path);;
            list)
                if [ -e \(root.appending(path: "created").path) ]; then
                    echo '{"devices":{"runtime":[{"udid":"\(identifier)","name":"fixture","isAvailable":true}]}}'
                else echo '{"devices":{}}'; fi;;
            bootstatus)
                [ "$3" = "\(identifier)" ] && [ "$4" = "-b" ] || exit 9
                touch \(booted.path);;
            delete) printf '%s' "$3" > \(deleted.path); rm \(root.appending(path: "created").path);;
            esac
            """.write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("[ -e \(booted.path) ] || exit 9; printf '%s\\n' \"$@\"; exit \(exitCode)", at: root)
        var runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        runner.simulatorPool = SimulatorPool(directory: root.appending(path: "Simulators"))
        runner.executionPool = try await Self.pool(at: root, maximumConcurrentJobs: 1)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.destination = .managedSimulator(Self.freshSimulator)
        request.arguments = ["-parallel-testing-enabled", "NO"]
        request.environment["DEVELOPER_DIR"] = root.appending(path: "SelectedXcode").path
        let result: XcodeBuildResult
        do { result = try await runner.run(.test, request: request) }
        catch let failure as XcodeBuildFailure { result = try #require(failure.result) }
        #expect(result.status == .exited(exitCode))
        #expect(result.simulatorIdentifier == identifier)
        #expect(try String(contentsOf: deleted, encoding: .utf8) == identifier)
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        #expect(log.contains("-destination\nid=\(identifier)\n"))
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
            create) touch \(root.appending(path: "created").path); echo \(identifier);;
            list)
                if [ -e \(root.appending(path: "created").path) ]; then
                    echo '{"devices":{"runtime":[{"udid":"\(identifier)","name":"fixture","isAvailable":true}]}}'
                else echo '{"devices":{}}'; fi;;
            bootstatus) echo boot-failed >&2; exit 9;;
            delete) printf '%s' "$3" > \(deleted.path); rm \(root.appending(path: "created").path);;
            esac
            """.write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("touch \(started.path)", at: root)
        var runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        runner.simulatorPool = SimulatorPool(directory: root.appending(path: "Simulators"))
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.destination = .managedSimulator(Self.freshSimulator)
        do {
            _ = try await runner.run(.testWithoutBuilding, request: request)
            Issue.record("Simulator boot failure returned successfully.")
        } catch let failure as XcodeBuildFailure {
            #expect(failure.result == nil)
            let error = try #require(failure.underlyingError)
            #expect((error as NSError).domain == "XcodeRunnerKit.simctl")
            #expect(error.localizedDescription.contains("boot-failed"))
            #expect(failure.cleanupErrors.isEmpty)
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
        try """
            #!/bin/sh
            case "$2" in
            create) touch \(root.appending(path: "created").path); echo \(identifier);;
            list)
                if [ -e \(root.appending(path: "created").path) ]; then
                    echo '{"devices":{"runtime":[{"udid":"\(identifier)","name":"fixture","isAvailable":true}]}}'
                else echo '{"devices":{}}'; fi;;
            delete) echo deletion-failed >&2; exit 9;;
            esac
            """.write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("exit 7", at: root)
        var runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        runner.simulatorPool = SimulatorPool(directory: root.appending(path: "Simulators"))
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root)
        request.destination = .managedSimulator(Self.freshSimulator)
        do {
            _ = try await runner.run(.test, request: request)
            Issue.record("Cleanup failure returned successfully.")
        } catch let failure as XcodeBuildFailure {
            #expect(failure.result?.status == .exited(7))
            #expect(failure.result?.simulatorIdentifier == identifier)
            #expect(failure.cleanupErrors.count == 1)
            let cleanup = try #require(failure.cleanupErrors.first as? SimulatorCleanupFailure)
            #expect(cleanup.simulatorIdentifier == identifier)
            #expect(cleanup.underlyingError.localizedDescription.contains("deletion-failed"))
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
        try """
            #!/bin/sh
            case "$2" in
            create) touch \(ready.path); sleep 1; touch \(root.appending(path: "created").path); echo \(identifier);;
            list)
                if [ -e \(root.appending(path: "created").path) ]; then
                    echo '{"devices":{"runtime":[{"udid":"\(identifier)","name":"fixture","isAvailable":true}]}}'
                else echo '{"devices":{}}'; fi;;
            delete) touch \(deleted.path); rm \(root.appending(path: "created").path);;
            esac
            """.write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        var runner = XcodeRunner(executableURL: root.appending(path: "must-not-start"), simulatorExecutableURL: simulator)
        runner.simulatorPool = SimulatorPool(directory: root.appending(path: "Simulators"))
        let configuredRunner = runner
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.destination = .managedSimulator(Self.freshSimulator)
        let configured = request
        let task = Task { try await configuredRunner.run(.test, request: configured) }
        defer { task.cancel() }
        try await waitForFile(ready)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled Simulator creation returned successfully.")
        } catch let failure as XcodeBuildFailure {
            #expect(failure.result == nil)
            #expect(failure.underlyingError is CancellationError)
        }
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
            create) touch \(root.appending(path: "created").path); echo \(identifier);;
            list)
                if [ -e \(root.appending(path: "created").path) ]; then
                    echo '{"devices":{"runtime":[{"udid":"\(identifier)","name":"fixture","isAvailable":true}]}}'
                else echo '{"devices":{}}'; fi;;
            delete)
                touch \(ready.path)
                while [ ! -e \(finish.path) ]; do sleep 0.02; done
                touch \(deleted.path)
                rm \(root.appending(path: "created").path);;
            esac
            """.write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("printf 'completed payload\\n'; exit \(exitCode)", at: root)
        var runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        runner.simulatorPool = SimulatorPool(directory: root.appending(path: "Simulators"))
        runner.executionPool = try await Self.pool(at: root, maximumConcurrentJobs: 1)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.destination = .managedSimulator(Self.freshSimulator)
        let configuredRunner = runner
        let configuredRequest = request
        let task = Task { try await configuredRunner.run(.test, request: configuredRequest) }
        defer {
            task.cancel()
            try? Data().write(to: finish)
        }
        try await waitForFile(ready)
        task.cancel()
        try Data().write(to: finish)
        do {
            _ = try await task.value
            Issue.record("Cancellation during Simulator deletion returned successfully.")
        } catch let failure as XcodeBuildFailure {
            let result = try #require(failure.result)
            #expect(result.status == (exitCode == 0 ? .cancelled : .exited(exitCode)))
            #expect(result.simulatorIdentifier == identifier)
            #expect(try String(contentsOf: result.logURL, encoding: .utf8).contains("completed payload"))
        }
        #expect(FileManager.default.fileExists(atPath: deleted.path))
        let pool = try #require(configuredRunner.executionPool)
        try await pool.withSlot {}
    }

    private static var freshSimulator: SimulatorConfiguration {
        var configuration = SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device")
        configuration.reusesDevice = false
        return configuration
    }

    private static func pool(at root: URL, maximumConcurrentJobs: Int) async throws -> HostExecutionPool {
        let pool = HostExecutionPool(directory: root.appending(path: "pool"))
        try await pool.configure(maximumConcurrentJobs: maximumConcurrentJobs)
        return pool
    }

    private func script(_ body: String, at root: URL) throws -> URL {
        let url = root.appending(path: "tool")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    private func waitForFile(_ url: URL) async throws {
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) }
    }

    private func waitForWaitingCount(_ count: Int, at priority: HostExecutionPool.Priority, in pool: HostExecutionPool) async throws {
        try await waitUntil { try await pool.status()?.waitingJobCounts[priority] == count }
    }
}
