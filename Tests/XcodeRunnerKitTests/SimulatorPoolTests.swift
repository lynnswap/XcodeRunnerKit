import Darwin
import Foundation
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
        let runner = fixture.runner
        var request = fixture.request("first")
        request.environment["LEASE_CHILD_GATE"] = gate.path
        request.environment["LEASE_CHILD_STARTED"] = started.path
        let firstRequest = request
        let first = Task { try await runner.run(.test, request: firstRequest) }
        defer { first.cancel() }

        try await waitForFile(started)
        let identifier = try String(contentsOf: fixture.root.appending(path: "started-first"), encoding: .utf8)
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
        let runner = fixture.runner
        var request = fixture.request("first")
        request.environment["BLOCK_CLEANUP"] = "1"
        let firstRequest = request
        let first = Task { try await runner.run(.test, request: firstRequest) }
        defer { first.cancel() }
        let started = fixture.root.appending(path: "started-first")
        try await waitForFile(started)
        let identifier = try String(contentsOf: started, encoding: .utf8)
        let gate = fixture.root.appending(path: "cleanup-gate-" + identifier)
        defer { try? FileManager.default.removeItem(at: gate) }
        try await waitForFile(fixture.root.appending(path: "cleanup-started-" + identifier))

        let second = try await runner.run(.test, request: fixture.request("second"))
        #expect(second.simulatorIdentifier != identifier)
        try FileManager.default.removeItem(at: gate)
        let firstResult = try await first.value
        #expect(firstResult.simulatorIdentifier == identifier)
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

    private func completedResult(_ runner: XcodeRunner, request: XcodeBuildRequest) async throws -> XcodeBuildResult {
        do { return try await runner.run(.test, request: request) }
        catch let failure as XcodeBuildFailure { return try #require(failure.result) }
    }

    private func waitForFile(_ url: URL) async throws {
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) }
    }

    private struct Fixture: Sendable {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        var poolDirectory: URL { root.appending(path: "pool") }

        init() throws {
            try FileManager.default.createDirectory(at: root.appending(path: "devices"), withIntermediateDirectories: true)
            try writeScript("""
                root='\(root.path)'
                (shift; printf '%s\\n' "$*") >> "$root/calls"
                case "$2" in
                create)
                    identifier=$(/usr/bin/uuidgen)
                    printf '%s' "$3" > "$root/devices/$identifier"
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
                delete) rm -f "$root/devices/$3" "$root/booted-$3";;
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

        func remove() { try? FileManager.default.removeItem(at: root) }

        private func writeScript(_ body: String, to url: URL) throws {
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
}
