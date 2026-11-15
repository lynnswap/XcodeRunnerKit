import ArgumentParser
import Foundation
import XcodeRunnerHostSupport
import XcodeRunnerKit

struct Host: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the installed runner host.",
        subcommands: [
            Status.self, Pause.self, Resume.self, Restart.self, Labels.self, GitHub.self, Pairing.self, Macs.self,
            Storage.self, BuildService.self, Settings.self,
        ]
    )

    // The app has these commands, with the requests that its window sends a host. Their options and help are its own.
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the host's state, jobs, runners, and settings as JSON.")
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() throws { try HostApp.run(["status"] + arguments) }
    }

    struct Pause: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take no new jobs.")
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() throws { try HostApp.run(["pause"] + arguments) }
    }

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take jobs again after a pause.")
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() throws { try HostApp.run(["resume"] + arguments) }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the host and start it again, with the jobs of its runners.")
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() throws { try HostApp.run(["restart"] + arguments) }
    }

    struct GitHub: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "github", abstract: "Connect the host to GitHub, and read its sign-in, repositories, and runners."
        )
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() throws { try HostApp.run(["github"] + arguments) }
    }

    struct Pairing: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pair this host with a dashboard or a managing Mac, and list or remove its pairings."
        )
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() throws { try HostApp.run(["pairing"] + arguments) }
    }

    struct Macs: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the Macs that the host manages, pair it with another one, or remove one."
        )
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() throws { try HostApp.run(["macs"] + arguments) }
    }

    struct Labels: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Replace the labels of this Mac's runners.")
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
        func run() throws { try HostApp.run(["labels"] + arguments) }
    }

    struct BuildService: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "build-service",
            abstract: "Inspect or configure the host's custom build service.",
            subcommands: [Status.self, Configure.self]
        )

        struct Status: AsyncParsableCommand {
            @Flag var json = false

            mutating func run() async throws {
                let installation = HostInstallation()
                try reportBuildService(installation, executable: installation.buildServiceExecutableURL(), json: json)
            }
        }

        struct Configure: AsyncParsableCommand {
            @Option(help: "Build service executable path. Omit to clear the host override.")
            var path: String?
            @Flag var json = false

            mutating func run() async throws {
                let installation = HostInstallation()
                let executable = try HostSettingsService(installation: installation).saveBuildServiceExecutableURL(path.map {
                    URL(filePath: $0, relativeTo: .currentDirectory())
                })
                try reportBuildService(installation, executable: executable, json: json)
            }
        }
    }

    struct Storage: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inspect or initialize the host's job-data directory.",
            subcommands: [Status.self, Configure.self]
        )

        struct Status: AsyncParsableCommand {
            @Flag var json = false

            mutating func run() async throws {
                let installation = HostInstallation()
                try report(installation, storage: installation.storage(), json: json)
            }
        }

        struct Configure: AsyncParsableCommand {
            @Option(help: "Parent directory for Work, CompilationCache, and Build. Omit to use the managed default.")
            var directory: String?
            @Flag var json = false

            mutating func run() async throws {
                let installation = HostInstallation()
                let storage = try installation.initializeStorage(at: directory.map {
                    URL(filePath: $0, relativeTo: .currentDirectory())
                })
                try report(installation, storage: storage, json: json)
            }
        }
    }

    struct Settings: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Inspect or update host settings as JSON.", subcommands: [Get.self, Update.self])

        struct Get: AsyncParsableCommand {
            @Option(help: "Return only this scope: pool, buildService, xcode, storage, githubRepositories, runnerLabels, or paused.")
            var scope: String?

            mutating func run() async throws {
                let selected = try scope.map { value in
                    guard let scope = HostSettingsScope(rawValue: value) else { throw ValidationError("Unknown settings scope: \(value)") }
                    return scope
                }
                try writeSettingsJSON(await HostSettingsService().getSettings(scope: selected))
            }
        }

        struct Update: AsyncParsableCommand {
            @Argument(help: "A JSON settings patch with a typed scope; unspecified fields are preserved.")
            var patch: String

            mutating func run() async throws {
                let update = try JSONDecoder().decode(HostSettingsUpdate.self, from: Data(patch.utf8))
                try writeSettingsJSON(await HostSettingsService().update(update))
            }
        }
    }
}

private func writeSettingsJSON(_ result: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(result) + Data("\n".utf8))
}

private struct HostBuildServiceStatus: Encodable {
    let hostRoot: String
    let buildServiceExecutablePath: String?
}

private func reportBuildService(_ installation: HostInstallation, executable: URL?, json: Bool) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let status = HostBuildServiceStatus(
            hostRoot: installation.hostRoot.path(percentEncoded: false),
            buildServiceExecutablePath: executable?.path(percentEncoded: false)
        )
        let data = try encoder.encode(status)
        try FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
    } else if let executable {
        print("Build service executable: \(executable.path(percentEncoded: false))")
    } else {
        print("Host build service is not configured.")
    }
}

private struct HostStorageStatus: Encodable {
    let hostRoot: String
    let runnersRoot: String
    let toolsDirectory: String
    let poolDirectory: String
    let logsDirectory: String
    let applicationsDirectory: String
    let storageDirectory: String?
    let workDirectory: String?
    let compilationCacheDirectory: String?
    let buildDirectory: String?

    init(_ installation: HostInstallation, storage: HostInstallation.Storage?) {
        hostRoot = installation.hostRoot.path(percentEncoded: false)
        runnersRoot = installation.runnersRoot.path(percentEncoded: false)
        toolsDirectory = installation.toolsDirectory.path(percentEncoded: false)
        poolDirectory = installation.poolDirectory.path(percentEncoded: false)
        logsDirectory = installation.logsDirectory.path(percentEncoded: false)
        applicationsDirectory = installation.applicationsDirectory.path(percentEncoded: false)
        storageDirectory = storage?.directory.path(percentEncoded: false)
        workDirectory = storage?.workDirectory.path(percentEncoded: false)
        compilationCacheDirectory = storage?.compilationCacheDirectory.path(percentEncoded: false)
        buildDirectory = storage?.buildDirectory.path(percentEncoded: false)
    }
}

private func report(_ installation: HostInstallation, storage: HostInstallation.Storage?, json: Bool) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(HostStorageStatus(installation, storage: storage))
        try FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
    } else if let storage {
        print("Job data: \(storage.directory.path(percentEncoded: false))")
    } else {
        print("Host storage is not configured.")
    }
}

/// The app that contains this `xcode-runner`. It runs what needs the app's Keychain items or its requests to a host.
enum HostApp {
    /// The app's executable, when this `xcode-runner` is the one inside the app.
    static func executable() -> URL? {
        guard let tool = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = tool.deletingLastPathComponent().deletingLastPathComponent().appending(path: "MacOS/XcodeHomeRunner")
        return FileManager.default.isExecutableFile(atPath: app.path(percentEncoded: false)) ? app : nil
    }

    /// Replaces this process with the app, which reads or changes a host as `command` says.
    static func run(_ command: [String]) throws -> Never {
        guard let app = executable() else {
            throw ValidationError("This command needs the xcode-runner inside XcodeHomeRunner.app, at Contents/Helpers/xcode-runner.")
        }
        try replaceProcess(with: [app.path(percentEncoded: false), "--control", "--"] + command)
    }

    static func replaceProcess(with arguments: [String]) throws -> Never {
        let values = arguments.map { strdup($0) } + [nil]
        execv(values[0], values)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: arguments[0]])
    }
}
