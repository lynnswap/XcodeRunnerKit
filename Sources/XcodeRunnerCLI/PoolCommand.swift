import ArgumentParser
import Foundation
import XcodeRunnerHostSupport
import XcodeRunnerKit

struct Pool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage a shared host execution pool and its idle Simulators.",
        subcommands: [Status.self, Configure.self, CleanSimulators.self]
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the maximum concurrent jobs, active jobs, and waiting jobs by priority without initializing the pool."
        )

        @OptionGroup private var options: PoolOptions
        @Flag(help: "Write JSON; an unconfigured pool is null.")
        var json = false

        mutating func run() async throws {
            try report(await options.pool().status(), json: json)
        }
    }

    struct Configure: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the maximum concurrent jobs while existing jobs continue running."
        )

        @OptionGroup private var options: PoolOptions
        @Option(help: "Maximum number of concurrent jobs; must be positive.")
        var maximumConcurrentJobs: Int?
        @Option(help: "Idle Simulator retention: forever or idleTimeout.")
        var simulatorRetention: String?
        @Option(help: "Minutes before deleting idle Simulators; requires --simulator-retention idleTimeout.")
        var idleTimeoutMinutes: Int?
        @Flag(help: "Write the resulting status as JSON.")
        var json = false

        mutating func run() async throws {
            let pool = try options.pool()
            let retention: HostExecutionPool.SimulatorRetention?
            switch simulatorRetention {
            case "forever":
                guard idleTimeoutMinutes == nil else { throw ValidationError("--idle-timeout-minutes requires idleTimeout retention.") }
                retention = .forever
            case "idleTimeout":
                guard let idleTimeoutMinutes else { throw ValidationError("Specify --idle-timeout-minutes with idleTimeout retention.") }
                retention = .idleTimeout(minutes: idleTimeoutMinutes)
            case nil:
                guard idleTimeoutMinutes == nil else { throw ValidationError("Specify --simulator-retention idleTimeout.") }
                retention = nil
            default: throw ValidationError("Expected forever or idleTimeout for --simulator-retention.")
            }
            guard maximumConcurrentJobs != nil || retention != nil else { throw ValidationError("Specify a pool setting to configure.") }
            try await HostSettingsService(pool: pool).configurePool(maximumConcurrentJobs: maximumConcurrentJobs, simulatorRetention: retention)
            try report(await pool.status(), json: json)
        }
    }

    struct CleanSimulators: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete idle Simulators owned by this pool. Simulators in use continue running."
        )

        @OptionGroup private var options: PoolOptions
        @Option(help: "Only remove devices registered with this Xcode developer directory.")
        var developerDirectory: String?

        mutating func run() async throws {
            try await options.pool().simulatorPool.removeIdleSimulators(
                developerDirectory: developerDirectory.map {
                    URL(filePath: $0, relativeTo: URL.currentDirectory()).standardizedFileURL
                }
            )
        }
    }
}

private struct PoolOptions: ParsableArguments {
    @Option(help: "Local directory shared by every repository runner on this Mac. Defaults to the installed host's pool.")
    var poolDirectory: String?

    func pool() throws -> HostExecutionPool {
        if let poolDirectory {
            return HostExecutionPool(directory: URL(filePath: poolDirectory, relativeTo: URL.currentDirectory()).standardizedFileURL)
        }
        return HostExecutionPool(directory: try HostInstallation.hostedPoolDirectory() ?? HostInstallation().poolDirectory)
    }
}

private func report(_ status: HostExecutionPool.Status?, json: Bool) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(status)
        try FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
        return
    }
    guard let status else {
        print("Pool is not configured.")
        return
    }
    print("Maximum concurrent jobs: \(status.configuration.maximumConcurrentJobs)")
    switch status.configuration.simulatorRetention {
    case .forever: print("Simulator retention: forever")
    case .idleTimeout(let minutes): print("Simulator retention: \(minutes) idle minutes")
    }
    print("Active jobs: \(status.activeJobCount)")
    let waiting = status.waitingJobCounts
    print("Waiting jobs: \(waiting.total) (high: \(waiting.high), medium: \(waiting.medium), low: \(waiting.low))")
}
