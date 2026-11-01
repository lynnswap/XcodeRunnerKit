import ArgumentParser

/// The CLI's entry point. Each `xcode-runner` executable calls `main()` from its `main.swift`.
public enum RunnerCommandLine {
    public static func main() async { await RunnerCommand.main() }
}

struct RunnerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-runner",
        abstract: "Run native Xcode builds and tests with preserved logs and result bundles.",
        subcommands: [Build.self, BuildForTesting.self, Test.self, TestWithoutBuilding.self, Pool.self, Host.self, SettingsMCP.self]
    )
}
