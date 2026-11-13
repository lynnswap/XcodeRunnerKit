import ArgumentParser
import Darwin
import Dispatch
import Foundation
import XcodeRunnerHostSupport
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
    @Option(help: "xcodebuild destination specifier (default: platform=macOS). Not used with Simulator options.")
    var destination: String?
    @Option(help: "Run on a host Mac that XcodeHomeRunner on this Mac shows, with the files of the Git checkout that contains the current directory. The log and result bundle are copied to --output-directory on this Mac, and --developer-directory names an Xcode on the host.")
    var host: String?
    @Option var outputDirectory: String?
    @Option var derivedData: String?
    @Option var developerDirectory: String?
    @Option(help: "Custom build service executable. Overrides the host's saved selection.")
    var buildServicePath: String?
    @Option(help: "Shared compiler CAS directory; DerivedData remains isolated.")
    var compilationCache: String?
    @Flag(help: "Emit compilation cache diagnostic remarks.")
    var cacheDiagnostics = false
    @Flag(help: "Share cache entries between checkouts at different paths. #filePath, __FILE__, test failure locations, debug information, and coverage data then name a placeholder instead of the checkout.")
    var mapSourceDirectory = false
    @Option(name: .customLong("prefix-mapping"), help: "Extra path=canonical-prefix mapping. May be repeated.")
    var prefixMappings: [String] = []
    @Option(help: "Runtime identifier for a Simulator reused between operations.")
    var simulatorRuntime: String?
    @Option(help: "Device type supported by --simulator-runtime.")
    var simulatorDeviceType: String?
    @Flag(help: "Create a separate Simulator and delete it after this operation. Requires the Simulator runtime and device type.")
    var freshSimulator = false
    @Option(help: "Local directory shared by every repository runner on this Mac.")
    var poolDirectory: String?
    @Option(name: .customLong("setting"), help: "A build setting in NAME=VALUE form. May be repeated.")
    var settings: [String] = []
    @Option(name: .customLong("environment"), help: "A child environment value in NAME=VALUE form. May be repeated.")
    var environment: [String] = []
    @Argument(parsing: .remaining, help: "Additional xcodebuild arguments after --.")
    var additionalArguments: [String] = []

    func run(_ action: XcodeBuildAction) async throws {
        if let host { try run(action, onHostNamed: host) }
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
            source: source, scheme: scheme, destination: try requestedDestination(),
            outputDirectory: outputDirectory.map(Self.url) ?? host?.storage.buildDirectory ?? Self.url("XcodeRunnerOutput")
        )
        request.derivedDataDirectory = derivedData.map(Self.url)
        let cache: CompilationCache?
        if let compilationCache {
            cache = CompilationCache(directory: Self.url(compilationCache))
        } else if let host {
            guard let value = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY_ID"],
                  let identifier = Int(value), identifier > 0 else {
                throw ValidationError("GITHUB_REPOSITORY_ID must be a positive integer to select the host's repository compilation cache.")
            }
            cache = CompilationCache(directory: host.storage.compilationCacheDirectory, namespace: String(identifier))
        } else {
            cache = nil
        }
        if var cache {
            cache.enablesDiagnosticRemarks = cacheDiagnostics
            cache.mapsSourceDirectory = mapSourceDirectory
            cache.prefixMappings = try Self.assignments(prefixMappings).sorted(by: { $0.key < $1.key }).map {
                CompilationCache.PrefixMapping(
                    source: URL(filePath: $0.key, relativeTo: URL.currentDirectory()).absoluteURL,
                    replacement: $0.value
                )
            }
            request.compilationCache = cache
        } else if cacheDiagnostics || mapSourceDirectory || !prefixMappings.isEmpty {
            throw ValidationError("Specify --compilation-cache with cache diagnostics, source directory mapping, or prefix mappings.")
        }
        request.environment = try Self.assignments(environment)
        request.buildSettings = try Self.assignments(settings)
        request.arguments = additionalArguments
        // The host's saved Xcode is for operations that name none, in an option or in DEVELOPER_DIR.
        let inheritsXcode = request.environment["DEVELOPER_DIR"] != nil
            || ProcessInfo.processInfo.environment["DEVELOPER_DIR"] != nil
        var runner = XcodeRunner(
            developerDirectory: developerDirectory.map(Self.url) ?? (inheritsXcode ? nil : host?.developerDirectory)
        )
        runner.buildServiceExecutableURL = buildServicePath.map(Self.url) ?? host?.buildServiceExecutableURL
        if let poolDirectory {
            runner.executionPool = HostExecutionPool(directory: Self.url(poolDirectory))
        } else if let host {
            runner.executionPool = HostExecutionPool(directory: host.poolDirectory)
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
        } catch let failure as XcodeBuildFailure {
            if let result = failure.result {
                Self.writeError("Log: " + result.logURL.path(percentEncoded: false))
            }
            let exitCode: Int32
            switch failure.result?.status {
            case .exited(let code)? where code != 0: exitCode = code
            case .terminated(let number)?: exitCode = 128 + number
            case .cancelled?: exitCode = 130
            case .exited?, .executionFailed?, nil:
                guard failure.underlyingError is CancellationError else { throw failure }
                exitCode = 130
            }
            // An exit code alone would hide cleanup failures that need attention.
            if !failure.cleanupErrors.isEmpty {
                Self.writeError("Error: " + failure.localizedDescription)
            }
            throw ExitCode(exitCode)
        }
    }

    /// Replaces this process with the app, which sends the checkout to the host and shows the operation's output.
    ///
    /// The pairings with hosts are in the app's Keychain item, and macOS gives it to the app alone.
    private func run(_ action: XcodeBuildAction, onHostNamed host: String) throws -> Never {
        guard action != .testWithoutBuilding else {
            throw ValidationError("A host keeps no build products after an operation. Use test with --host.")
        }
        let localFolders = [
            ("--derived-data", derivedData), ("--compilation-cache", compilationCache), ("--pool-directory", poolDirectory),
            ("--build-service-path", buildServicePath),
        ].filter { $0.1 != nil }.map(\.0)
        guard localFolders.isEmpty else {
            throw ValidationError("\(localFolders.joined(separator: ", ")) cannot be used with --host. The host uses its own folders and build service.")
        }
        let sources = [workspace, project, package].compactMap { $0 }
        guard sources.count == 1, let source = sources.first else {
            throw ValidationError("Specify exactly one of --workspace, --project, or --package.")
        }
        // The host runs the operation in its copy of the current directory.
        guard !source.hasPrefix("/") else {
            throw ValidationError("With --host, name the workspace, project, or package relative to the current directory.")
        }
        _ = try requestedDestination()
        guard let tool = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw ValidationError("Cannot locate the xcode-runner executable.")
        }
        let app = tool.deletingLastPathComponent().deletingLastPathComponent().appending(path: "MacOS/XcodeHomeRunner")
        guard FileManager.default.isExecutableFile(atPath: app.path(percentEncoded: false)) else {
            throw ValidationError("--host needs the xcode-runner inside XcodeHomeRunner.app, at Contents/Helpers/xcode-runner.")
        }
        let arguments = [
            app.path(percentEncoded: false), "--run-on-host", host,
            "--output-directory", Self.url(outputDirectory ?? "XcodeRunnerOutput").path(percentEncoded: false),
            "--", action.rawValue,
        ] + hostArguments
        let values = arguments.map { strdup($0) } + [nil]
        execv(values[0], values)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSURLErrorKey: app])
    }

    /// The options that a host takes: every option except `--host` and those that name this Mac's folders.
    private var hostArguments: [String] {
        var arguments: [String] = []
        func add(_ name: String, _ value: String?) {
            if let value { arguments.append("--\(name)=\(value)") }
        }
        add("workspace", workspace)
        add("project", project)
        add("package", package)
        add("scheme", scheme)
        add("destination", destination)
        add("developer-directory", developerDirectory)
        if cacheDiagnostics { arguments.append("--cache-diagnostics") }
        if mapSourceDirectory { arguments.append("--map-source-directory") }
        for mapping in prefixMappings { add("prefix-mapping", mapping) }
        add("simulator-runtime", simulatorRuntime)
        add("simulator-device-type", simulatorDeviceType)
        if freshSimulator { arguments.append("--fresh-simulator") }
        for setting in settings { add("setting", setting) }
        for value in environment { add("environment", value) }
        if !additionalArguments.isEmpty { arguments += ["--"] + additionalArguments }
        return arguments
    }

    private static func writeError(_ line: String) {
        try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
    }

    private func requestedDestination() throws -> XcodeBuildDestination {
        guard let simulatorRuntime, let simulatorDeviceType else {
            if simulatorRuntime != nil || simulatorDeviceType != nil {
                throw ValidationError("Specify both --simulator-runtime and --simulator-device-type.")
            }
            if freshSimulator {
                throw ValidationError("Specify --simulator-runtime and --simulator-device-type with --fresh-simulator.")
            }
            return .specifier(destination ?? "platform=macOS")
        }
        guard destination == nil else {
            throw ValidationError("Specify either --destination or the Simulator options, not both.")
        }
        var configuration = SimulatorConfiguration(runtimeIdentifier: simulatorRuntime, deviceTypeIdentifier: simulatorDeviceType)
        configuration.reusesDevice = !freshSimulator
        return .managedSimulator(configuration)
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
