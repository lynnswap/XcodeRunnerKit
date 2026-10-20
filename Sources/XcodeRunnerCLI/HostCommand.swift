import ArgumentParser
import Foundation
import XcodeRunnerHostSupport
import XcodeRunnerKit

struct Host: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the installed runner host.", subcommands: [Storage.self, BuildService.self]
    )

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
                let executable = try installation.saveBuildServiceExecutableURL(path.map {
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
