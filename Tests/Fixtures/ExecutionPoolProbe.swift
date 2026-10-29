import Darwin
import Dispatch
import Foundation
import XcodeRunnerKit

/// Uses the production package for the separate-process execution pool checks.
@main
struct ExecutionPoolProbe {
    static func main() async throws {
        let values = CommandLine.arguments
        let root = URL(filePath: values[1])
        let identifier = values[2]
        if identifier == "status" || identifier == "update" {
            do {
                let pool = HostExecutionPool(directory: root.appending(path: "pool"))
                if identifier == "update" {
                    try await pool.configure(maximumConcurrentJobs: Int(values[3])!)
                }
                let data = try JSONEncoder().encode(try await pool.status())
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
                exit(1)
            }
            return
        }
        let priority = values.count > 3 ? HostExecutionPool.Priority(rawValue: values[3])! : .medium
        let pool = HostExecutionPool(directory: root.appending(path: "pool"))
        let task = Task {
            try await pool.withSlot(priority: priority) {
                try "\(getpid())".write(to: root.appending(path: identifier + ".started"), atomically: true, encoding: .utf8)
                while !FileManager.default.fileExists(atPath: root.appending(path: identifier + ".release").path) {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in task.cancel() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        try Data().write(to: root.appending(path: identifier + ".ready"))
        do { try await task.value }
        catch is CancellationError { exit(130) }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
