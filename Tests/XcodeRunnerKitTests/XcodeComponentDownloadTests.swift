import Darwin
import Foundation
import Testing
@testable import XcodeRunnerKit

@Suite(.timeLimit(.minutes(1)))
struct XcodeComponentDownloadTests {
    enum Outcome: String, CaseIterable, Sendable {
        case success, downloadFailure, stillMissing, unrelatedFailure
    }

    @Test(arguments: Outcome.allCases)
    func metalDownloadRecoversOnlyTheMissingToolchain(_ outcome: Outcome) async throws {
        let root = URL.temporaryDirectory.appending(path: "Component tests " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script("""
        if [ "$1" = '-downloadComponent' ]; then
            printf '%s\\n' "$*" "$DEVELOPER_DIR" "$TEST_VALUE" >> "$COMPONENT_TEST_ROOT/calls"
            echo 'download output'
            if [ "$OUTCOME" = downloadFailure ]; then echo 'download failed' >&2; exit 9; fi
            touch "$COMPONENT_TEST_ROOT/installed"
            exit 0
        fi
        echo build >> "$COMPONENT_TEST_ROOT/calls"
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '-resultBundlePath' ]; then shift; bundle="$1"; fi
            shift
        done
        mkdir "$bundle" || exit 3
        if [ "$OUTCOME" = unrelatedFailure ]; then echo 'unrelated compiler error'; exit 65; fi
        if [ ! -e "$COMPONENT_TEST_ROOT/installed" ] || [ "$OUTCOME" = stillMissing ]; then
            echo "error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain"
            echo first > "$bundle/attempt"
            exit 65
        fi
        echo second > "$bundle/attempt"
        echo 'build succeeded'
        """, named: "xcodebuild", at: root)
        var request = XcodeBuildRequest(source: .package(root), scheme: "Probe", outputDirectory: root.appending(path: "output"))
        request.environment = ["COMPONENT_TEST_ROOT": root.path, "OUTCOME": outcome.rawValue, "TEST_VALUE": "kept"]
        let runner = XcodeRunner(executableURL: executable, developerDirectory: URL(filePath: "/Selected Xcode/Contents/Developer"))
        let streamed = root.appending(path: "streamed")
        try Data().write(to: streamed)
        let handle = try FileHandle(forWritingTo: streamed)
        defer { try? handle.close() }
        let result: XcodeBuildResult
        do {
            result = try await runner.run(.build, request: request) { try handle.write(contentsOf: $0) }
            #expect(outcome == .success)
        } catch let failure as XcodeBuildFailure {
            #expect(outcome != .success)
            result = try #require(failure.result)
            if outcome == .downloadFailure {
                #expect(failure.underlyingError?.localizedDescription.contains("download failed") == true)
                #expect(result.status == .executionFailed)
            } else {
                #expect(result.status == .exited(65))
            }
        }
        let calls = try String(contentsOf: root.appending(path: "calls"), encoding: .utf8)
        let retry = outcome == .success || outcome == .stillMissing
        let expectedCalls = "build\n" + (outcome == .unrelatedFailure ? "" : "-downloadComponent MetalToolchain\n/Selected Xcode/Contents/Developer\nkept\n") + (retry ? "build\n" : "")
        #expect(calls == expectedCalls)
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        #expect(log == (try String(contentsOf: streamed, encoding: .utf8)))
        let firstBundle = result.jobDirectory.appending(path: "Results-before-component-download.xcresult")
        #expect(FileManager.default.fileExists(atPath: firstBundle.path) == retry)
        if outcome == .success {
            #expect(log.contains("download output"))
            #expect(log.contains("build succeeded"))
            #expect(try String(contentsOf: firstBundle.appending(path: "attempt"), encoding: .utf8) == "first\n")
            #expect(try String(contentsOf: result.resultBundleURL.appending(path: "attempt"), encoding: .utf8) == "second\n")
        }
    }

    @Test func cancellingDownloadTerminatesItsChildrenAndReleasesTheLock() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script("""
        sleep 120 &
        child=$!
        echo "$child" > "$COMPONENT_TEST_ROOT/child"
        touch "$COMPONENT_TEST_ROOT/ready"
        wait "$child"
        """, named: "download", at: root)
        let tool = XcodeComponentTool(executableURL: executable, environment: ["COMPONENT_TEST_ROOT": root.path], lockURL: root.appending(path: "download.lock"))
        let task = Task { try await tool.download(arguments: ["-downloadComponent", "MetalToolchain"]) }
        try await waitUntil { FileManager.default.fileExists(atPath: root.appending(path: "ready").path) }
        task.cancel()
        do {
            try await task.value
            Issue.record("The cancelled download succeeded")
        } catch is CancellationError { }
        let child = try #require(Int32(try String(contentsOf: root.appending(path: "child"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await waitUntil { kill(child, 0) == -1 && errno == ESRCH }
        var next = tool
        next.executableURL = try script("echo completed", named: "next", at: root)
        try await next.download(arguments: ["-downloadComponent", "MetalToolchain"])
    }

    private func script(_ body: String, named name: String, at root: URL) throws -> URL {
        let url = root.appending(path: name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
