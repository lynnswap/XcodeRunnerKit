import ArgumentParser
import Foundation

/// The CLI's entry point. Each `xcode-runner` executable calls `main()` from its `main.swift`.
public enum RunnerCommandLine {
    public static func main() async { await RunnerCommand.main() }
}

struct RunnerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-runner",
        abstract: "Run native Xcode builds and tests with preserved logs and result bundles.",
        subcommands: [Build.self, BuildForTesting.self, Test.self, TestWithoutBuilding.self, Workflow.self, Pool.self, Host.self, SettingsMCP.self]
    )
}

struct Workflow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a GitHub Actions workflow with the current checkout on a paired runner.",
        subcommands: [Run.self]
    )

    struct Run: AsyncParsableCommand {
        @Argument(help: "Workflow YAML, relative to the current directory.") var file: String
        @Option(help: "GitHub event to simulate.") var event = "workflow_dispatch"
        @Option(help: "Target branch for a pull request event (defaults to origin’s default branch).") var base: String?
        @Option(help: "Where this Mac receives the workflow log and artifacts.") var outputDirectory = "XcodeRunnerOutput"

        func run() throws {
            guard let app = HostApp.executable() else {
                throw ValidationError("Workflow runs need the CLI inside the paired XcodeHomeRunner.app.")
            }
            try HostApp.replaceProcess(with: [
                app.path(percentEncoded: false), "--run-on-available-host", "--output-directory",
                URL(filePath: outputDirectory).standardizedFileURL.path(percentEncoded: false), "--", "workflow", file, event, base ?? "",
            ])
        }
    }
}
