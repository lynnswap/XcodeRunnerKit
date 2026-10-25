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

/// A Simulator that could not be prepared for reuse or deleted.
///
/// Remove a remaining managed device with SimulatorPool.removeIdleSimulators,
/// or use `xcrun simctl delete` with its identifier.
public struct SimulatorCleanupFailure: Error, LocalizedError {
    /// The device's UDID, or nil when it failed before simctl reported one.
    public let simulatorIdentifier: String?
    /// The name the runner gave the device when creating it.
    public let simulatorName: String
    public let underlyingError: any Error

    public var errorDescription: String? {
        let device = simulatorIdentifier.map { "Simulator \(simulatorName) (\($0))" } ?? "Simulator \(simulatorName)"
        return "\(device) could not be cleaned up: \(underlyingError.localizedDescription)"
    }
}

struct SimulatorTool: Sendable {
    var executableURL = URL(filePath: "/usr/bin/xcrun")
    var developerDirectory: URL?
    var inheritedLeaseDescriptor: Int32?
    var componentTool: XcodeComponentTool?
    var componentOutput: (@Sendable (Data) throws -> Void)?

    func create(_ configuration: SimulatorConfiguration, name: String) async throws -> String {
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

    private struct Runtime: Decodable {
        let identifier: String
        let isAvailable: Bool
        let availabilityError: String?

        func requireAvailable() throws {
            guard isAvailable else {
                throw NSError(domain: "XcodeRunnerKit.simctl", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Simulator runtime \(identifier) is unavailable: \(availabilityError ?? "simctl reported that the runtime cannot be used.")",
                ])
            }
        }
    }

    private func runtime(_ identifier: String) async throws -> Runtime? {
        struct Listing: Decodable { let runtimes: [Runtime] }
        let output = try await call(["list", "runtimes", "--json"])
        return try JSONDecoder().decode(Listing.self, from: Data(output.utf8)).runtimes.first { $0.identifier == identifier }
    }

    func prepareRuntime(_ identifier: String) async throws {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard let componentTool, identifier.hasPrefix(prefix) else { return }
        let parts = identifier.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        let platforms = ["iOS": "iOS", "tvOS": "tvOS", "watchOS": "watchOS", "xrOS": "visionOS"]
        guard parts.count >= 3, let runtimePlatform = parts.first, let platform = platforms[String(runtimePlatform)],
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return }
        if let installed = try await runtime(identifier) {
            try installed.requireAvailable()
            return
        }
        try await componentTool.download(
            arguments: ["-downloadPlatform", platform, "-buildVersion", parts.dropFirst().joined(separator: ".")],
            onOutput: componentOutput
        )
        guard let installed = try await runtime(identifier) else {
            throw NSError(domain: "XcodeRunnerKit.simctl", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Simulator runtime \(identifier) is still missing after downloading its requested version.",
            ])
        }
        try installed.requireAvailable()
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
        try await devices().contains { $0.udid == identifier && $0.isAvailable }
    }

    private struct Device: Decodable {
        let name: String
        let udid: String
        let isAvailable: Bool
    }

    private func devices() async throws -> [Device] {
        struct Listing: Decodable { let devices: [String: [Device]] }
        let output = try await call(["list", "devices", "--json"])
        return try JSONDecoder().decode(Listing.self, from: Data(output.utf8)).devices.values.flatMap { $0 }
    }

    /// Boots the device before removing test apps and resetting the state supported by simctl.
    /// Tests that change system app data or arbitrary device settings must request a fresh device.
    func prepareForReuse(_ identifier: String) async throws {
        try await boot(identifier)
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
