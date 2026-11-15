import ArgumentParser
import Foundation
import XcodeRunnerHostSupport

/// The commands of `xcode-runner host` that read and change a host as its window does.
///
/// `xcode-runner` starts the app with them after `--control --`: they send a host the requests that a dashboard
/// sends it, whose types are the app's, and the host answers them as it answers a dashboard. Each command prints the
/// host's answer as JSON, and fails with the host's reason when the host refuses.
struct HostControl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-runner host",
        abstract: "Read and change the host on this Mac.",
        subcommands: [Status.self, Pause.self, Resume.self, Restart.self, Labels.self, GitHub.self]
    )

    /// The GitHub pane's controls. The repository selection is a setting of `xcode-runner host settings`.
    struct GitHub: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "github",
            abstract: "Connect the host to GitHub, and read its sign-in, repositories, and runners.",
            subcommands: [Status.self, Connect.self, Cancel.self, Disconnect.self, Reload.self]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the sign-in, the repositories, and their runners as JSON."
            )

            func run() async throws { try await HostControl.perform(.github(.read)) }
        }

        struct Connect: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Start a sign-in and print the code to enter on GitHub's page.",
                discussion: """
                    The answer's `signInCode` has the code and the page. The host finishes the sign-in once the code \
                    is entered there; `github status` then names the account. With --wait the command returns when \
                    the sign-in has ended, and fails if it ended without an account.
                    """
            )

            @Flag(help: "Print the code, then wait until the sign-in has ended and print the result.")
            var wait = false

            func run() async throws {
                // The window offers no sign-in while an account is connected, and a sign-in that failed then would
                // leave that account in place of a result.
                if let login = try await HostControl.github().accountLogin {
                    throw HostSettingsError("The host is connected to GitHub as \(login). Disconnect it before connecting again.")
                }
                guard case .github(var report) = try await HostControl.reply(to: .github(.signIn)) else {
                    throw HostControl.unexpectedAnswer
                }
                // The host answers before GitHub issues the code, so that a dashboard can cancel meanwhile.
                while report.isConnecting, report.signInCode == nil {
                    try await Task.sleep(for: .milliseconds(500))
                    report = try await HostControl.github()
                }
                try HostControl.write(report)
                guard report.signInCode != nil else {
                    throw HostSettingsError(report.errorMessage ?? "The sign-in ended before GitHub issued a code.")
                }
                guard wait else { return }
                while report.isConnecting {
                    try await Task.sleep(for: .seconds(2))
                    report = try await HostControl.github()
                }
                try HostControl.write(report)
                guard report.accountLogin != nil else {
                    throw HostSettingsError(report.errorMessage ?? "The sign-in ended without an account.")
                }
            }
        }

        struct Cancel: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "End a sign-in that waits for its code.")

            func run() async throws { try await HostControl.perform(.github(.cancelSignIn)) }
        }

        struct Disconnect: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Sign the host out of GitHub. Its runners stay registered until it is connected again."
            )

            func run() async throws { try await HostControl.change(.signOut) }
        }

        struct Reload: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Read again which repositories the GitHub App is installed on."
            )

            func run() async throws { try await HostControl.change(.reloadRepositories) }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the host's state, jobs, runners, and settings as JSON."
        )

        func run() async throws { try await HostControl.perform(.settings(.read)) }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Take no new jobs. Runner services stop after the jobs that they run."
        )

        func run() async throws { try await HostControl.perform(.settings(.setPaused(true))) }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take jobs again after a pause.")

        func run() async throws { try await HostControl.perform(.settings(.setPaused(false))) }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the host and start it again. Its runner services stop with the jobs that they run."
        )

        @Flag(help: "Restart although Xcode jobs run on this Mac. The jobs of its runners end.")
        var stopJobs = false

        func run() async throws {
            // The window names the running jobs before a person confirms, and a command is refused in their place.
            // The count is the host's last, as it is in the window: a job can start after it.
            if !stopJobs, case .settings(let report) = try await HostControl.reply(to: .settings(.read)) {
                let running = report.poolStatus?.activeJobCount
                guard running == 0 else {
                    let jobs = switch running {
                    case nil: "The host has not counted the Xcode jobs"
                    case 1: "An Xcode job runs"
                    case let count?: "\(count) Xcode jobs run"
                    }
                    throw HostSettingsError(
                        "\(jobs) on this Mac. Restarting ends the jobs of its runners: wait for them, or pass --stop-jobs."
                    )
                }
            }
            try await HostControl.perform(.settings(.restart))
        }
    }

    struct Labels: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace the labels of this Mac's runners. `status` prints the current ones."
        )

        @Argument(help: "The labels that the runners get beside the ones that GitHub sets.")
        var labels: [String] = []
        @Flag(help: "Leave the runners with no label of their own.")
        var none = false

        func validate() throws {
            guard labels.isEmpty == none else {
                throw ValidationError("Name the labels, or pass --none to remove them all.")
            }
        }

        func run() async throws { try await HostControl.perform(.settings(.saveRunnerLabels(labels))) }
    }

    static var unexpectedAnswer: HostSettingsError {
        HostSettingsError("The host answered with something else than what the command asked for.")
    }

    /// Sends this Mac's host a request and prints its answer.
    @MainActor static func perform(_ request: HostLinkRequest) async throws {
        switch try await reply(to: request) {
        case .settings(let report): try write(report)
        case .github(let report): try write(report)
        default: throw unexpectedAnswer
        }
    }

    /// Signs the host out or reloads its repositories, and prints its answer. The host reports what went wrong with
    /// GitHub or the Keychain in its answer, and clears that after either succeeds, so it is the command's failure.
    @MainActor static func change(_ request: GitHubRequest) async throws {
        guard case .github(let report) = try await reply(to: .github(request)) else { throw unexpectedAnswer }
        try write(report)
        if let error = report.errorMessage { throw HostSettingsError(error) }
    }

    /// Reads the host's GitHub sign-in, repositories, and runners.
    @MainActor static func github() async throws -> GitHubReport {
        guard case .github(let report) = try await reply(to: .github(.read)) else { throw unexpectedAnswer }
        return report
    }

    static func write(_ answer: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(answer) + Data("\n".utf8))
    }

    /// Sends this Mac's host a request and returns its answer. Throws the host's reason when it refuses.
    ///
    /// - Parameter bridge: Sends the request to the running host. Tests pass a connection to a host of their own.
    @MainActor static func reply(
        to request: HostLinkRequest,
        over bridge: (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = HostSettingsBridge.request
    ) async throws -> HostLinkReply {
        let response = try await bridge(.link(JSONEncoder().encode(request)))
        if let error = response.error { throw HostSettingsError(error) }
        guard let data = response.reply else {
            throw HostSettingsError("The host that runs on this Mac does not take this command. Update it and try again.")
        }
        let reply = try JSONDecoder().decode(HostLinkReply.self, from: data)
        if case .refused(let reason) = reply { throw HostSettingsError(reason) }
        return reply
    }
}
