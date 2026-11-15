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
        subcommands: [Status.self, Pause.self, Resume.self, Restart.self, Labels.self, GitHub.self, Pairing.self]
    )

    /// The window's Management and Dashboards sections: the Macs that this host is paired with.
    ///
    /// Two Macs pair once each was told the code that the other shows, which is the same code unless someone on the
    /// network changed the keys between them. In the window a person compares the codes; `confirm` takes the other
    /// Mac's code and compares it itself, so whoever runs commands on both Macs pairs them.
    struct Pairing: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pair this host with a dashboard or a managing Mac, and list or remove its pairings.",
            subcommands: [Status.self, Allow.self, Confirm.self, Refuse.self, Cancel.self, Remove.self, StopManagement.self]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the paired Macs, and the Mac that asks to pair with its code, as JSON."
            )

            func run() async throws { try HostControl.write(try await HostControl.pairing(.read)) }
        }

        struct Allow: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Wait five minutes for a Mac to pair as a dashboard or as the managing Mac."
            )

            @Argument(help: "dashboard: shows this Mac and changes its settings. manager: registers this Mac's runners too.")
            var role: PairingRole
            @Flag(help: "Return once a Mac asked to pair and shows its code, or the wait ended.")
            var wait = false

            func run() async throws {
                var report = try await HostControl.pairing(.allow(role))
                // A wait that starts after this one ended is another one, with another Mac's request.
                let allowed = report.window?.id
                while wait, let window = report.window, window.id == allowed, window.code == nil {
                    try await Task.sleep(for: .seconds(1))
                    report = try await HostControl.pairing(.read)
                }
                try HostControl.write(report)
                if wait, report.window?.id != allowed {
                    throw HostSettingsError(report.message ?? "The wait for a Mac to pair ended.")
                }
            }
        }

        struct Confirm: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Allow the Mac that asks to pair, given the code that it shows.",
                discussion: """
                    The request is refused if this Mac shows another code for it. The command returns once the Macs \
                    are paired, which needs the other Mac's confirmation as well, and fails if they did not pair.
                    """
            )

            @Argument(help: "The code that the other Mac shows for this pairing.")
            var code: String

            func run() async throws {
                var report = try await HostControl.pairing(.confirm(code: code))
                // The wait ends when the other Mac confirmed too, refused, or left, or when its time is over. A wait
                // that starts afterwards is another one.
                let confirmed = report.window?.id
                while let window = report.window, window.id == confirmed {
                    try await Task.sleep(for: .seconds(1))
                    report = try await HostControl.pairing(.read)
                }
                try HostControl.write(report)
                guard let ended = report.ended, ended.id == confirmed, ended.paired != nil else {
                    throw HostSettingsError(report.errorMessage ?? report.message ?? "The Macs did not pair.")
                }
            }
        }

        struct Refuse: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Refuse the Mac that asks to pair, and stop waiting.")

            func run() async throws { try HostControl.write(try await HostControl.pairing(.refuse)) }
        }

        struct Cancel: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Stop waiting for a Mac to pair.")

            func run() async throws { try HostControl.write(try await HostControl.pairing(.cancel)) }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Forget a dashboard. It can no longer connect until the Macs pair again."
            )

            @Argument(help: "The dashboard's name or ID, as `status` prints them.")
            var dashboard: String

            func run() async throws {
                let dashboards = try await HostControl.pairing(.read).dashboards
                let named = dashboards.filter { $0.name == dashboard || $0.id.uuidString.caseInsensitiveCompare(dashboard) == .orderedSame }
                guard let match = named.first else {
                    throw HostSettingsError("This host is paired with no dashboard named \(dashboard).")
                }
                guard named.count == 1 else {
                    throw HostSettingsError("This host is paired with \(named.count) dashboards named \(dashboard). Pass the ID of one.")
                }
                try HostControl.write(try await HostControl.pairing(.removeDashboard(match.id)))
            }
        }

        struct StopManagement: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "stop-management",
                abstract: "Forget the managing Mac. It can no longer connect until the Macs pair again."
            )

            func run() async throws { try HostControl.write(try await HostControl.pairing(.stopManagement)) }
        }
    }

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
                let current = try await HostControl.github()
                // Until the host has read its saved sign-in, it shows no account although it may have one.
                guard current.hasRestored else {
                    throw HostSettingsError("The host has not read its saved GitHub sign-in yet. Try again in a moment.")
                }
                if let login = current.accountLogin {
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

    /// Asks this Mac's host about its pairings, or to change them. Throws the host's reason when it refuses.
    ///
    /// - Parameter bridge: Sends the request to the running host. Tests pass a connection to a host of their own.
    @MainActor static func pairing(
        _ request: HostPairingRequest,
        over bridge: (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = HostSettingsBridge.request
    ) async throws -> HostPairingReport {
        let response = try await bridge(.pairing(JSONEncoder().encode(request)))
        if let error = response.error { throw HostSettingsError(error) }
        guard let data = response.reply else {
            throw HostSettingsError("The host that runs on this Mac does not take this command. Update it and try again.")
        }
        return try JSONDecoder().decode(HostPairingReport.self, from: data)
    }

    static func write(_ answer: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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

extension PairingRole: ExpressibleByArgument {}
