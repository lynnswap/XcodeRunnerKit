import ArgumentParser
import Foundation
import XcodeRunnerKit

struct Pool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect or configure a shared host execution pool.",
        subcommands: [Status.self, Configure.self]
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show capacity, active jobs, and waiting jobs by priority without initializing the pool."
        )

        @OptionGroup private var options: PoolOptions
        @Flag(help: "Write JSON; an unconfigured pool is null.")
        var json = false

        mutating func run() async throws {
            let pool = try options.pool()
            let status = try await pool.status()
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(status)
                try FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
            } else {
                printStatus(status)
            }
        }
    }

    struct Configure: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the pool capacity while existing jobs continue running."
        )

        @OptionGroup private var options: PoolOptions
        @Option(help: "Maximum number of concurrent jobs; must be positive.")
        var maximumConcurrentJobs: Int

        mutating func run() async throws {
            let pool = try options.pool(initialCapacity: maximumConcurrentJobs)
            try await pool.updateMaximumConcurrentJobs(to: maximumConcurrentJobs)
            printStatus(try await pool.status())
        }
    }
}

private struct PoolOptions: ParsableArguments {
    @Option(help: "Local directory shared by every repository runner on this Mac.")
    var poolDirectory: String

    func pool(initialCapacity: Int = 1) throws -> HostExecutionPool {
        try HostExecutionPool(
            directory: URL(filePath: poolDirectory, relativeTo: URL.currentDirectory()).standardizedFileURL,
            initialCapacity: initialCapacity
        )
    }
}

private func printStatus(_ status: HostExecutionPool.Status?) {
    guard let status else {
        print("Pool is not configured.")
        return
    }
    print("Maximum concurrent jobs: \(status.maximumConcurrentJobs)")
    print("Active jobs: \(status.activeJobCount)")
    let waiting = status.waitingJobCounts
    print("Waiting jobs: \(waiting.total) (high: \(waiting.high), normal: \(waiting.normal), low: \(waiting.low))")
}
