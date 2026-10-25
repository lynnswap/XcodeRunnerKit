import Foundation
import Testing
@testable import XcodeRunnerKit

@Suite(.timeLimit(.minutes(1)))
struct SimulatorRuntimeDownloadTests {
    @Test func missingRequestedRuntimeIsDownloadedBeforeDeviceCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRuntimes([], to: "before.json")
        try fixture.writeRuntimes([Fixture.availableRuntime], to: "after.json")
        let output = fixture.root.appending(path: "output")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let result = try await fixture.run { try handle.write(contentsOf: $0) }

        #expect(result.simulatorIdentifier == Fixture.deviceIdentifier)
        let calls = try fixture.calls()
        #expect(Array(calls.prefix(3)) == [
            "simctl:\(fixture.developerDirectory.path):simctl list runtimes --json",
            "download:\(fixture.developerDirectory.path):-downloadPlatform iOS -buildVersion 27.0",
            "simctl:\(fixture.developerDirectory.path):simctl list runtimes --json",
        ])
        let creation = try #require(calls.first { $0.contains("simctl create XcodeRunnerKit-") })
        #expect(creation.hasSuffix(" device \(Fixture.runtimeIdentifier)"))
        #expect(calls.last == "simctl:\(fixture.developerDirectory.path):simctl delete \(Fixture.deviceIdentifier)")
        #expect(try String(contentsOf: output, encoding: .utf8) == "runtime download output\nbuild output\n")
    }

    @Test func installedRequestedRuntimeDoesNotDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRuntimes([Fixture.availableRuntime], to: "before.json")

        _ = try await fixture.run()

        #expect(!(try fixture.calls()).contains { $0.hasPrefix("download:") })
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "created").path))
    }

    @Test func visionOSRuntimeUsesItsDownloadPlatformName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtimeIdentifier = "com.apple.CoreSimulator.SimRuntime.xrOS-27-0"
        try fixture.writeRuntimes([], to: "before.json")
        try fixture.writeRuntimes([["identifier": runtimeIdentifier, "isAvailable": true]], to: "after.json")
        try await fixture.tool.prepareRuntime(runtimeIdentifier)

        #expect(try fixture.calls().contains("download:\(fixture.developerDirectory.path):-downloadPlatform visionOS -buildVersion 27.0"))
    }

    @Test func unavailableRequestedRuntimeReportsItsReasonWithoutDownloading() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRuntimes([[
            "identifier": Fixture.runtimeIdentifier,
            "isAvailable": false,
            "availabilityError": "Runtime is incompatible with this host.",
        ]], to: "before.json")

        do {
            _ = try await fixture.run()
            Issue.record("An unavailable runtime was used to create a device.")
        } catch {
            #expect(error.localizedDescription.contains("Runtime is incompatible with this host."))
        }
        #expect(!(try fixture.calls()).contains { $0.hasPrefix("download:") })
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "created").path))
    }

    @Test func downloadingAnotherVersionDoesNotCreateADevice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRuntimes([], to: "before.json")
        try fixture.writeRuntimes([[
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "isAvailable": true,
        ]], to: "after.json")

        do {
            _ = try await fixture.run()
            Issue.record("A different runtime version was accepted.")
        } catch {
            #expect(error.localizedDescription.contains(Fixture.runtimeIdentifier))
            #expect(error.localizedDescription.contains("still missing"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "created").path))
    }

    @Test func downloadFailurePreventsDeviceCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRuntimes([], to: "before.json")
        try Data().write(to: fixture.root.appending(path: "fail-download"))

        await #expect(throws: (any Error).self) {
            _ = try await fixture.run()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "created").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "downloaded").path))
    }

    private struct Fixture {
        static let runtimeIdentifier = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        static let deviceIdentifier = "01010101-0202-0303-0404-050505050505"
        static var availableRuntime: [String: Any] {
            ["identifier": runtimeIdentifier, "isAvailable": true]
        }

        let root: URL
        var developerDirectory: URL { root.appending(path: "Selected Xcode/Contents/Developer") }
        var configuration: SimulatorConfiguration {
            var configuration = SimulatorConfiguration(runtimeIdentifier: Self.runtimeIdentifier, deviceTypeIdentifier: "device")
            configuration.reusesDevice = false
            return configuration
        }
        var tool: SimulatorTool {
            SimulatorTool(
                executableURL: root.appending(path: "xcrun"), developerDirectory: developerDirectory,
                componentTool: XcodeComponentTool(
                    executableURL: root.appending(path: "xcodebuild"),
                    environment: ["DEVELOPER_DIR": developerDirectory.path],
                    lockURL: root.appending(path: "ComponentDownloads.lock")
                )
            )
        }

        init() throws {
            root = URL.temporaryDirectory.appending(path: "Runtime download " + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try writeScript("""
                root=$(dirname "$0")
                printf 'simctl:%s:%s\\n' "$DEVELOPER_DIR" "$*" >> "$root/calls"
                if [ "$2" = list ] && [ "$3" = runtimes ]; then
                    if [ -e "$root/downloaded" ]; then cat "$root/after.json"; else cat "$root/before.json"; fi
                elif [ "$2" = list ] && [ "$3" = devices ]; then
                    if [ -e "$root/device-present" ]; then
                        printf '%s\\n' '{"devices":{"runtime":[{"udid":"\(Self.deviceIdentifier)","name":"fixture","isAvailable":true}]}}'
                    else printf '%s\\n' '{"devices":{}}'; fi
                elif [ "$2" = create ]; then
                    touch "$root/created" "$root/device-present"
                    printf '%s\\n' '\(Self.deviceIdentifier)'
                elif [ "$2" = delete ]; then
                    touch "$root/deleted"
                    rm "$root/device-present"
                else
                    exit 1
                fi
                """, name: "xcrun")
            try writeScript("""
                root=$(dirname "$0")
                if [ "$1" != -downloadPlatform ]; then
                    printf 'build:%s:%s\\n' "$DEVELOPER_DIR" "$1" >> "$root/calls"
                    printf 'build output\\n'
                    exit 0
                fi
                printf 'download:%s:%s\\n' "$DEVELOPER_DIR" "$*" >> "$root/calls"
                printf 'runtime download output\\n'
                if [ -e "$root/fail-download" ]; then exit 9; fi
                touch "$root/downloaded"
                """, name: "xcodebuild")
        }

        func run(onOutput: (@Sendable (Data) throws -> Void)? = nil) async throws -> XcodeBuildResult {
            var runner = XcodeRunner(
                executableURL: root.appending(path: "xcodebuild"), developerDirectory: developerDirectory,
                simulatorExecutableURL: root.appending(path: "xcrun")
            )
            runner.simulatorPool = SimulatorPool(directory: root.appending(path: "Simulators"))
            let request = XcodeBuildRequest(
                source: .package(root), scheme: "Probe", destination: .managedSimulator(configuration),
                outputDirectory: root.appending(path: "Build")
            )
            return try await runner.run(.build, request: request, onOutput: onOutput)
        }

        func writeRuntimes(_ runtimes: [[String: Any]], to name: String) throws {
            try JSONSerialization.data(withJSONObject: ["runtimes": runtimes]).write(to: root.appending(path: name))
        }

        func calls() throws -> [String] {
            try String(contentsOf: root.appending(path: "calls"), encoding: .utf8).split(separator: "\n").map(String.init)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private func writeScript(_ body: String, name: String) throws {
            let url = root.appending(path: name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
}
