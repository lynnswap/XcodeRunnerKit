import Darwin
import Foundation
import Subprocess

/// An explicit runtime/device pairing from simctl's supportedDeviceTypes metadata.
public struct SimulatorConfiguration: Sendable {
    public var runtimeIdentifier: String
    public var deviceTypeIdentifier: String
    /// Reuses an exclusively leased device. Set to false for a new device per operation.
    public var reusesDevice: Bool = true

    public init(runtimeIdentifier: String, deviceTypeIdentifier: String) {
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
    }
}

/// Failed Simulator resource cleanup or deletion, preserving the operation's outcome.
public struct SimulatorCleanupFailure: Error, LocalizedError {
    public let simulatorIdentifier: String
    public let operationError: (any Error)?
    /// The completed build, if execution succeeded before cleanup failed.
    public let result: XcodeBuildResult?
    public let cleanupError: any Error

    public var errorDescription: String? {
        let original = operationError.map { "Operation failed: \($0). " } ?? ""
        return original + "Simulator \(simulatorIdentifier) could not be cleaned up: \(cleanupError)."
    }
}

struct SimulatorTool: Sendable {
    var executableURL = URL(filePath: "/usr/bin/xcrun")
    var developerDirectory: URL?
    var inheritedLeaseDescriptor: Int32?

    func create(_ configuration: SimulatorConfiguration, name: String = "XcodeRunnerKit-" + UUID().uuidString) async throws -> String {
        let output = try await call([
            "create", name,
            configuration.deviceTypeIdentifier, configuration.runtimeIdentifier,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identifier = UUID(uuidString: output) else {
            throw NSError(domain: "XcodeRunnerKit.simctl", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "simctl create returned an invalid device identifier: \(output)",
            ])
        }
        return identifier.uuidString
    }

    func boot(_ identifier: String) async throws {
        _ = try await call(["bootstatus", identifier, "-b"])
    }

    func delete(_ identifier: String) async throws {
        _ = try await call(["delete", identifier])
    }

    func delete(identifier: String?, name: String) async throws {
        for device in try await devices() {
            let matches = identifier.map { device.udid == $0 } ?? (device.name == name)
            guard matches else { continue }
            try await delete(device.udid)
        }
    }

    func containsDevice(_ identifier: String) async throws -> Bool {
        try await devices().contains { $0.udid == identifier }
    }

    private struct Device: Decodable { let name: String; let udid: String }

    private func devices() async throws -> [Device] {
        struct Listing: Decodable { let devices: [String: [Device]] }
        let output = try await call(["list", "devices", "--json"])
        return try JSONDecoder().decode(Listing.self, from: Data(output.utf8)).devices.values.flatMap { $0 }
    }

    /// Removes installed test apps and resets the state supported by simctl while staying booted.
    /// Tests that change system app data or arbitrary device settings must request a fresh device.
    func prepareForReuse(_ identifier: String) async throws {
        let output = try await call(["listapps", identifier])
        let plist = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil)
        guard let applications = plist as? [String: [String: Any]] else {
            throw NSError(domain: "XcodeRunnerKit.simctl", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "simctl listapps returned an invalid application listing.",
            ])
        }
        for (bundleIdentifier, application) in applications.sorted(by: { $0.key < $1.key })
            where application["ApplicationType"] as? String == "User" {
            _ = try await call(["uninstall", identifier, bundleIdentifier])
        }
        for arguments in [
            ["keychain", identifier, "reset"],
            ["privacy", identifier, "reset", "all"],
            ["status_bar", identifier, "clear"],
            ["location", identifier, "clear"],
        ] {
            _ = try await call(arguments)
        }
    }

    static func selectedDeveloperDirectory(_ explicit: URL?) async throws -> URL {
        if let explicit { return explicit.standardizedFileURL.resolvingSymlinksInPath() }
        let result = try await Subprocess.run(
            .path("/usr/bin/xcode-select"), arguments: ["-p"],
            output: .string(limit: 65_536), error: .string(limit: 65_536)
        )
        guard result.terminationStatus.isSuccess else {
            throw NSError(domain: "XcodeRunnerKit.xcode-select", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "xcode-select -p failed: \(result.standardError)",
            ])
        }
        return URL(filePath: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    private func call(_ arguments: [String]) async throws -> String {
        var options = PlatformOptions()
        options.createSession = true
        options.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)]
        if let inheritedLeaseDescriptor {
            // An in-flight simctl operation keeps its lease if the parent is killed.
            options.preSpawnProcessConfigurator = { _, fileActions in
                let error = posix_spawn_file_actions_addinherit_np(&fileActions, inheritedLeaseDescriptor)
                guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
            }
        }
        var environment: [Environment.Key: String?] = [:]
        if let developerDirectory {
            environment["DEVELOPER_DIR"] = developerDirectory.path(percentEncoded: false)
        }
        let result = try await Subprocess.run(
            .path(.init(executableURL.path(percentEncoded: false))),
            arguments: .init(["simctl"] + arguments),
            environment: .inherit.updating(environment),
            platformOptions: options,
            output: .string(limit: 1_048_576),
            error: .string(limit: 1_048_576)
        )
        guard result.terminationStatus.isSuccess else {
            throw NSError(domain: "XcodeRunnerKit.simctl", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "simctl \(arguments.joined(separator: " ")) failed: \(result.terminationStatus). \(result.standardError)",
            ])
        }
        return result.standardOutput
    }
}
