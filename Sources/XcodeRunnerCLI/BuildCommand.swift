import ArgumentParser
import Darwin
import Dispatch
import Foundation
import XcodeRunnerKit

protocol BuildActionCommand: AsyncParsableCommand {
    static var action: XcodeBuildAction { get }
    var options: BuildOptions { get }
}

extension BuildActionCommand {
    mutating func run() async throws {
        try await options.run(Self.action)
    }
}

struct Build: BuildActionCommand {
    static let configuration = CommandConfiguration(abstract: "Build an Xcode project, workspace, or package.")
    static let action = XcodeBuildAction.build
    @OptionGroup var options: BuildOptions
}

struct BuildForTesting: BuildActionCommand {
    static let configuration = CommandConfiguration(commandName: "build-for-testing", abstract: "Build test products for later execution.")
    static let action = XcodeBuildAction.buildForTesting
    @OptionGroup var options: BuildOptions
}

struct Test: BuildActionCommand {
    static let configuration = CommandConfiguration(abstract: "Build and run tests.")
    static let action = XcodeBuildAction.test
    @OptionGroup var options: BuildOptions
}

struct TestWithoutBuilding: BuildActionCommand {
    static let configuration = CommandConfiguration(commandName: "test-without-building", abstract: "Run tests from an existing DerivedData directory.")
    static let action = XcodeBuildAction.testWithoutBuilding
    @OptionGroup var options: BuildOptions
}

struct BuildOptions: ParsableArguments {
    @Option var workspace: String?
    @Option var project: String?
    @Option var package: String?
    @Option var scheme: String
    @Option var destination = "platform=macOS"
    @Option var outputDirectory: String?
    @Option var derivedData: String?
    @Option var developerDirectory: String?
    @Option(help: "Shared compiler CAS directory; DerivedData remains isolated.")
    var compilationCache: String?
    @Flag(help: "Emit compilation cache diagnostic remarks.")
    var cacheDiagnostics = false
    @Option(name: .customLong("prefix-mapping"), help: "Extra physical-path=canonical-prefix mapping. May be repeated.")
    var prefixMappings: [String] = []
    @Option(help: "Runtime identifier for a new, job-owned iOS Simulator.")
    var simulatorRuntime: String?
    @Option(help: "Device type supported by --simulator-runtime.")
    var simulatorDeviceType: String?
    @Option(help: "Local directory shared by every repository runner on this Mac.")
    var poolDirectory: String?
    @Option(help: "Capacity for a new shared pool. Existing pools use their saved capacity. Required with --pool-directory.")
    var maximumConcurrentJobs: Int?
    @Option(
        help: "Local admission priority with --pool-directory: high, normal, or low (default: normal). Running jobs continue; GitHub dispatch is unaffected.",
        completion: .list(HostExecutionPool.Priority.allCases.map(\.rawValue)),
        transform: { value in
            guard let priority = HostExecutionPool.Priority(rawValue: value) else {
                throw ValidationError("Expected high, normal, or low for --priority: " + value)
            }
            return priority
        }
    )
    var priority: HostExecutionPool.Priority = .normal
    @Option(name: .customLong("setting"), help: "A build setting in NAME=VALUE form. May be repeated.")
    var settings: [String] = []
    @Option(name: .customLong("environment"), help: "A child environment value in NAME=VALUE form. May be repeated.")
    var environment: [String] = []
    @Argument(parsing: .remaining, help: "Additional xcodebuild arguments after --.")
    var additionalArguments: [String] = []

    func run(_ action: XcodeBuildAction) async throws {
        let host = try HostInstallation.hostedConfiguration()
        let sources: [XcodeBuildSource] = [
            workspace.map { .workspace(Self.url($0)) },
            project.map { .project(Self.url($0)) },
            package.map { .package(Self.url($0)) },
        ].compactMap { $0 }
        guard sources.count == 1, let source = sources.first else {
            throw ValidationError("Specify exactly one of --workspace, --project, or --package.")
        }
        var request = XcodeBuildRequest(
            source: source, scheme: scheme, destination: destination,
            outputDirectory: outputDirectory.map(Self.url) ?? host?.storage.buildDirectory ?? Self.url("XcodeRunnerOutput")
        )
        request.derivedDataDirectory = derivedData.map(Self.url)
        if let cacheDirectory = compilationCache.map(Self.url) ?? host?.storage.compilationCacheDirectory {
            var cache = CompilationCache(directory: cacheDirectory)
            cache.enablesDiagnosticRemarks = cacheDiagnostics
            cache.prefixMappings = try Self.assignments(prefixMappings).sorted(by: { $0.key < $1.key }).map {
                CompilationCache.PrefixMapping(
                    source: URL(filePath: $0.key, relativeTo: URL.currentDirectory()).absoluteURL,
                    replacement: $0.value
                )
            }
            request.compilationCache = cache
        } else if cacheDiagnostics || !prefixMappings.isEmpty {
            throw ValidationError("Specify --compilation-cache with cache diagnostics or prefix mappings.")
        }
        if let simulatorRuntime, let simulatorDeviceType {
            request.simulator = SimulatorConfiguration(
                runtimeIdentifier: simulatorRuntime, deviceTypeIdentifier: simulatorDeviceType
            )
        } else if simulatorRuntime != nil || simulatorDeviceType != nil {
            throw ValidationError("Specify both --simulator-runtime and --simulator-device-type.")
        }
        request.environment = try Self.assignments(environment)
        request.buildSettings = try Self.assignments(settings)
        request.arguments = additionalArguments
        var runner = XcodeRunner(developerDirectory: developerDirectory.map(Self.url))
        if let poolDirectory, let maximumConcurrentJobs {
            runner.executionPool = try HostExecutionPool(
                directory: Self.url(poolDirectory), initialCapacity: maximumConcurrentJobs
            )
        } else if poolDirectory != nil || maximumConcurrentJobs != nil {
            throw ValidationError("Specify both --pool-directory and --maximum-concurrent-jobs.")
        } else if let host {
            runner.executionPool = try HostExecutionPool(directory: host.poolDirectory, initialCapacity: 4)
        }
        let configuredRunner = runner
        let executionPriority = priority
        let task = Task {
            try await configuredRunner.run(action, request: request, priority: executionPriority) { data in
                try FileHandle.standardOutput.write(contentsOf: data)
            }
        }
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in task.cancel() }
            source.resume()
            return source
        }
        defer {
            for source in signals { source.cancel() }
        }
        do {
            let result = try await task.value
            print("Log: \(result.logURL.path(percentEncoded: false))")
            print("Result bundle: \(result.resultBundleURL.path(percentEncoded: false))")
        } catch is CancellationError {
            throw ExitCode(130)
        } catch let failure as XcodeBuildFailure {
            try? FileHandle.standardError.write(contentsOf: Data(("Log: " + failure.result.logURL.path(percentEncoded: false) + "\n").utf8))
            switch failure.result.status {
            case .exited(let code) where code != 0: throw ExitCode(code)
            case .exited: throw failure
            case .terminated(let number): throw ExitCode(128 + number)
            case .cancelled: throw ExitCode(130)
            case .executionFailed: throw failure
            }
        }
    }

    private static func url(_ path: String) -> URL {
        URL(filePath: path, relativeTo: URL.currentDirectory()).standardizedFileURL
    }

    private static func assignments(_ values: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            let pieces = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[0].isEmpty else {
                throw ValidationError("Expected NAME=VALUE: " + value)
            }
            result[String(pieces[0])] = String(pieces[1])
        }
        return result
    }
}
