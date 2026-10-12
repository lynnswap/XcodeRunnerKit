import ArgumentParser

@main
struct RunnerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-runner",
        abstract: "Run native Xcode builds and tests with preserved logs and result bundles.",
        subcommands: [Build.self, BuildForTesting.self, Test.self, TestWithoutBuilding.self, Pool.self, Host.self]
    )
}
