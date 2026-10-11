import Darwin
import Foundation
import Testing
@testable import XcodeRunnerKit

struct XcodeRunnerKitTests {
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
        let executable = try script("sleep 120 &\nchild=$!\nprintf '%s %s\\n' \"$$\" \"$child\" > \"$READY_PATH\"\nwait \"$child\"", at: root)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root)
        request.environment["READY_PATH"] = marker.path(percentEncoded: false)
        var runner = XcodeRunner(executableURL: executable)
        runner.executionPool = try HostExecutionPool(directory: root.appending(path: "pool"), maximumConcurrentJobs: 1)
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
        let pool = try HostExecutionPool(directory: blocked, maximumConcurrentJobs: 2)
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
        try ("#!/bin/sh\ncase \"$2\" in\ncreate) echo " + identifier + ";;\ndelete) printf '%s' \"$3\" > " + deleted.path + ";;\nesac\n")
            .write(to: simulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: simulator.path)
        let executable = try script("printf '%s\\n' \"$@\"; exit \(exitCode)", at: root)
        var runner = XcodeRunner(executableURL: executable, simulatorExecutableURL: simulator)
        runner.executionPool = try HostExecutionPool(directory: root.appending(path: "pool"), maximumConcurrentJobs: 1)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.simulator = SimulatorConfiguration(runtimeIdentifier: "runtime", deviceTypeIdentifier: "device")
        let result: XcodeBuildResult
        do { result = try await runner.run(.test, request: request) }
        catch let failure as XcodeBuildFailure { result = failure.result }
        #expect(result.status == .exited(exitCode))
        #expect(result.simulatorIdentifier == identifier)
        #expect(try String(contentsOf: deleted, encoding: .utf8) == identifier)
        #expect(try String(contentsOf: result.logURL, encoding: .utf8).contains("platform=iOS Simulator,id=" + identifier))
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

    private func script(_ body: String, at root: URL) throws -> URL {
        let url = root.appending(path: "tool")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }
}
