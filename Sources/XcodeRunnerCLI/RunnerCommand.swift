import ArgumentParser
import Darwin
import Dispatch
import Foundation
import XcodeRunnerKit

@main
struct RunnerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-runner",
        abstract: "Run native Xcode builds and tests with preserved logs and result bundles."
    )

    @Argument(help: "build, build-for-testing, test, or test-without-building.")
    var action: String
    @Option var workspace: String?
    @Option var project: String?
    @Option var package: String?
    @Option var scheme: String
    @Option var destination = "platform=macOS"
    @Option var outputDirectory = "XcodeRunnerOutput"
    @Option var derivedData: String?
    @Option var developerDirectory: String?
    @Option(help: "Local directory shared by every repository runner on this Mac.")
    var poolDirectory: String?
    @Option(help: "Shared pool capacity. Required with --pool-directory.")
    var maximumConcurrentJobs: Int?
    @Option(name: .customLong("setting"), help: "A build setting in NAME=VALUE form. May be repeated.")
    var settings: [String] = []
    @Option(name: .customLong("environment"), help: "A child environment value in NAME=VALUE form. May be repeated.")
    var environment: [String] = []
    @Argument(parsing: .remaining, help: "Additional xcodebuild arguments after --.")
    var additionalArguments: [String] = []

    mutating func run() async throws {
        guard let action = XcodeBuildAction(rawValue: action) else {
            throw ValidationError("Unknown Xcode action.")
        }
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
            outputDirectory: Self.url(outputDirectory)
        )
        request.derivedDataDirectory = derivedData.map(Self.url)
        request.environment = try Self.assignments(environment)
        request.buildSettings = try Self.assignments(settings)
        request.arguments = additionalArguments
        var runner = XcodeRunner(developerDirectory: developerDirectory.map(Self.url))
        if let poolDirectory, let maximumConcurrentJobs {
            runner.executionPool = try HostExecutionPool(
                directory: Self.url(poolDirectory), maximumConcurrentJobs: maximumConcurrentJobs
            )
        } else if poolDirectory != nil || maximumConcurrentJobs != nil {
            throw ValidationError("Specify both --pool-directory and --maximum-concurrent-jobs.")
        }
        let configuredRunner = runner
        let task = Task {
            try await configuredRunner.run(action, request: request) { data in
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
