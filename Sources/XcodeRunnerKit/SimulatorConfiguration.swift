import Foundation
import Subprocess

/// An explicit runtime/device pairing from simctl's supportedDeviceTypes metadata.
public struct SimulatorConfiguration: Sendable {
    public var runtimeIdentifier: String
    public var deviceTypeIdentifier: String

    public init(runtimeIdentifier: String, deviceTypeIdentifier: String) {
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
    }
}

/// A failed Simulator deletion, with any preceding build failure preserved.
public struct SimulatorCleanupFailure: Error, LocalizedError {
    public let simulatorIdentifier: String
    public let operationError: (any Error)?
    /// The completed build, if execution succeeded before cleanup failed.
    public let result: XcodeBuildResult?
    public let cleanupError: any Error

    public var errorDescription: String? {
        let original = operationError.map { "Operation failed: \($0). " } ?? ""
        return original + "Simulator \(simulatorIdentifier) could not be deleted: \(cleanupError)."
    }
}

struct SimulatorTool: Sendable {
    var executableURL = URL(filePath: "/usr/bin/xcrun")
    var developerDirectory: URL?

    func create(_ configuration: SimulatorConfiguration) async throws -> String {
        let output = try await call([
            "create", "XcodeRunnerKit-" + UUID().uuidString,
            configuration.deviceTypeIdentifier, configuration.runtimeIdentifier,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identifier = UUID(uuidString: output) else {
            throw NSError(domain: "XcodeRunnerKit.simctl", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "simctl create returned an invalid device identifier: \(output)",
            ])
        }
        return identifier.uuidString
    }

    func delete(_ identifier: String) async throws {
        _ = try await call(["delete", identifier])
    }

    private func call(_ arguments: [String]) async throws -> String {
        var options = PlatformOptions()
        options.createSession = true
        options.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)]
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
