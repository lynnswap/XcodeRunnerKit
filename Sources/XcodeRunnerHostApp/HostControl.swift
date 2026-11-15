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
        subcommands: [Status.self, Pause.self, Resume.self, Restart.self, Labels.self, GitHub.self, Pairing.self, Macs.self]
    )

    /// The Macs that a host manages: the Runners section of its window. The host pairs with a Mac that allowed a
    /// managing host, with `pairing allow manager` there, and then registers that Mac's runners as its own.
    struct Macs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the Macs that the host manages, pair it with another one, or remove one.",
            subcommands: [Status.self, Pair.self, Remove.self]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the Macs that the host manages, with their states and settings, as JSON."
            )

            @OptionGroup var host: HostOption

            func run() async throws { try HostControl.write(try await HostControl.macs(.read(refreshing: nil), on: host.host)) }
        }

        struct Pair: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Pair the host with a Mac that waits for a managing host, given the code that the Mac shows.",
                discussion: """
                    Run `xcode-runner host pairing allow manager` on the Mac first. This command has the host find \
                    the Mac and prints the code that the host shows for the pairing. It then reads the code that \
                    the Mac shows from standard input, and has the host pair if the two are the same. The Mac needs \
                    the host's code as well, with `xcode-runner host pairing confirm`.
                    """
            )

            @Argument(help: "The Mac's name, as it is named on the network.")
            var mac: String
            @Option(help: "How many seconds the host looks for the Mac.")
            var timeout = 60
            @OptionGroup var host: HostOption

            func run() async throws {
                let mac = mac
                let report = try await HostControl.pairManagedMac(named: mac, on: host.host, timeout: .seconds(timeout)) { shown in
                    try HostControl.write(shown)
                } otherCode: {
                    // Reading blocks its thread, and the host is read meanwhile.
                    let line = await Task.detached { readLine() }.value
                    guard let code = line?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                        throw HostSettingsError("Standard input ended without the code that \(mac) shows.")
                    }
                    return code
                }
                try HostControl.write(report)
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "End the host's pairing with a Mac that it manages. The Mac's runners stay registered."
            )

            @Argument(help: "The Mac's name or ID, as `status` prints them.")
            var mac: String
            @OptionGroup var host: HostOption

            func run() async throws {
                let host = host.host
                let listed = try await HostControl.macs(.read(refreshing: nil), on: host).macs.filter {
                    $0.name == mac || $0.id.uuidString.caseInsensitiveCompare(mac) == .orderedSame
                }
                guard let match = listed.first else { throw HostSettingsError("The host manages no Mac named \(mac).") }
                guard listed.count == 1 else {
                    throw HostSettingsError("The host manages \(listed.count) Macs named \(mac). Pass the ID of one.")
                }
                let report = try await HostControl.macs(.remove(mac: match.id), on: host)
                try HostControl.write(report)
                if report.macs.contains(where: { $0.id == match.id }) {
                    throw HostSettingsError(report.message ?? "The host could not remove \(mac).")
                }
            }
        }
    }

    /// The window's Management and Dashboards sections: the Macs that this host is paired with.
    ///
    /// Two Macs pair once each was told the code that the other shows, which is the same code unless someone on the
    /// network changed the keys between them. In the window a person compares the codes; `confirm` takes the other
    /// Mac's code and compares it itself, so whoever runs commands on both Macs pairs them.
    struct Pairing: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pair this host with a dashboard or a managing Mac, and list or remove its pairings.",
            subcommands: [
                Status.self, Allow.self, Confirm.self, Refuse.self, Cancel.self, Request.self, Remove.self, StopManagement.self,
            ]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the paired Macs, and the Mac that asks to pair with its code, as JSON."
            )

            func run() async throws {
                // A Mac without a host is a dashboard, and its pairings are the hosts that it shows.
                guard await HostControl.runsHost else {
                    let hosts = await HostControl.dashboardHosts()
                    return try HostControl.write(await DashboardPairingReport(hosts))
                }
                try HostControl.write(try await HostControl.pairing(.read))
            }
        }

        struct Request: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Pair this Mac's dashboard with a host that waits for one, given the code that the host shows.",
                discussion: """
                    Run `xcode-runner host pairing allow dashboard` on the host first. This command finds the host \
                    on the local network and prints the code that this Mac shows for the pairing. It then reads the \
                    code that the host shows from standard input, and pairs if the two are the same. The host needs \
                    this Mac's code as well, with `xcode-runner host pairing confirm`.
                    """
            )

            @Argument(help: "The host's name, as its Mac is named on the network.")
            var host: String
            @Option(help: "How many seconds to look for the host.")
            var timeout = 60

            func run() async throws {
                guard await !HostControl.runsHost else {
                    throw HostSettingsError("This Mac runs a host, which pairs with the Macs that it manages in its window.")
                }
                let hosts = await HostControl.dashboardHosts()
                // A host that this Mac is paired with already is told to forget that pairing, if it is found.
                await hosts.start()
                await hosts.discoverPairableMacs()
                let deadline = ContinuousClock.now + .seconds(timeout)
                var found: PairedMacs.PairableMac?
                while found == nil {
                    let named = await hosts.pairableMacs.filter { $0.name == host }
                    guard named.count <= 1 else {
                        throw HostSettingsError("\(named.count) Macs named \(host) wait to pair. Rename one, or pair in the window.")
                    }
                    found = named.first
                    if found == nil {
                        guard ContinuousClock.now < deadline else {
                            throw HostSettingsError(
                                await hosts.discoveryMessage ?? "No Mac named \(host) waits for a dashboard on the local network."
                            )
                        }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
                guard let found else { return }
                _ = try await hosts.pair(with: found.id) { shown in
                    try HostControl.write(shown)
                } otherCode: {
                    // Reading blocks its thread, and the Macs' connection needs the main actor meanwhile.
                    let line = await Task.detached { readLine() }.value
                    guard let code = line?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                        throw HostSettingsError("Standard input ended without the code that \(host) shows.")
                    }
                    return code
                }
                HostControl.dashboardHostsChanged()
                try HostControl.write(await DashboardPairingReport(hosts))
                await hosts.stopDiscoveringPairableMacs()
                await hosts.shutDown()
            }
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
                guard await HostControl.runsHost else { return try await removeHost() }
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

            /// Removes a host from this Mac's dashboard, and tells the host if it is found on the network.
            @MainActor private func removeHost() async throws {
                let hosts = HostControl.dashboardHosts()
                let named = hosts.macs.filter { $0.name == dashboard || $0.id.uuidString.caseInsensitiveCompare(dashboard) == .orderedSame }
                guard let match = named.first else {
                    throw HostSettingsError("This Mac's dashboard shows no host named \(dashboard).")
                }
                guard named.count == 1 else {
                    throw HostSettingsError("This Mac's dashboard shows \(named.count) hosts named \(dashboard). Pass the ID of one.")
                }
                // The host forgets this Mac when it is told, so it is looked for first.
                hosts.start()
                let deadline = ContinuousClock.now + .seconds(5)
                while hosts.status(of: match.id) != .online, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(250))
                }
                await hosts.remove(match.id)
                HostControl.dashboardHostsChanged()
                try HostControl.write(DashboardPairingReport(hosts))
                let stayed = hosts.macs.contains { $0.id == match.id }
                await hosts.shutDown()
                if stayed { throw HostSettingsError(hosts.message ?? "Could not remove \(match.name).") }
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

            @OptionGroup var host: HostOption

            func run() async throws { try await HostControl.perform(.github(.read), on: host.host) }
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
            @OptionGroup var host: HostOption

            func run() async throws {
                // The window offers no sign-in while an account is connected, and a sign-in that failed then would
                // leave that account in place of a result.
                let host = host.host
                let current = try await HostControl.github(on: host)
                // Until the host has read its saved sign-in, it shows no account although it may have one.
                guard current.hasRestored else {
                    throw HostSettingsError("The host has not read its saved GitHub sign-in yet. Try again in a moment.")
                }
                if let login = current.accountLogin {
                    throw HostSettingsError("The host is connected to GitHub as \(login). Disconnect it before connecting again.")
                }
                guard case .github(var report) = try await HostControl.reply(to: .github(.signIn), on: host) else {
                    throw HostControl.unexpectedAnswer
                }
                // The host answers before GitHub issues the code, so that a dashboard can cancel meanwhile.
                while report.isConnecting, report.signInCode == nil {
                    try await Task.sleep(for: .milliseconds(500))
                    report = try await HostControl.github(on: host)
                }
                try HostControl.write(report)
                guard report.signInCode != nil else {
                    throw HostSettingsError(report.errorMessage ?? "The sign-in ended before GitHub issued a code.")
                }
                guard wait else { return }
                while report.isConnecting {
                    try await Task.sleep(for: .seconds(2))
                    report = try await HostControl.github(on: host)
                }
                try HostControl.write(report)
                guard report.accountLogin != nil else {
                    throw HostSettingsError(report.errorMessage ?? "The sign-in ended without an account.")
                }
            }
        }

        struct Cancel: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "End a sign-in that waits for its code.")

            @OptionGroup var host: HostOption

            func run() async throws { try await HostControl.perform(.github(.cancelSignIn), on: host.host) }
        }

        struct Disconnect: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Sign the host out of GitHub. Its runners stay registered until it is connected again."
            )

            @OptionGroup var host: HostOption

            func run() async throws { try await HostControl.change(.signOut, on: host.host) }
        }

        struct Reload: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Read again which repositories the GitHub App is installed on."
            )

            @OptionGroup var host: HostOption

            func run() async throws { try await HostControl.change(.reloadRepositories, on: host.host) }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the host's state, jobs, runners, and settings as JSON."
        )

        @OptionGroup var host: HostOption
        @OptionGroup var mac: MacOption

        func run() async throws { try await HostControl.perform(.read, host: host.host, mac: mac.mac) }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Take no new jobs. Runner services stop after the jobs that they run."
        )

        @OptionGroup var host: HostOption
        @OptionGroup var mac: MacOption

        func run() async throws { try await HostControl.perform(.setPaused(true), host: host.host, mac: mac.mac) }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take jobs again after a pause.")

        @OptionGroup var host: HostOption
        @OptionGroup var mac: MacOption

        func run() async throws { try await HostControl.perform(.setPaused(false), host: host.host, mac: mac.mac) }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the host and start it again. Its runner services stop with the jobs that they run."
        )

        @Flag(help: "Restart although Xcode jobs run on the Mac. The jobs of its runners end.")
        var stopJobs = false
        @OptionGroup var host: HostOption
        @OptionGroup var mac: MacOption

        func run() async throws {
            // The window names the running jobs before a person confirms, and a command is refused in their place.
            // The count is the host's last, as it is in the window: a job can start after it.
            if !stopJobs {
                let running = try await HostControl.settings(host: host.host, mac: mac.mac)?.poolStatus?.activeJobCount
                guard running == 0 else {
                    let jobs = switch running {
                    case nil: "The host has not counted the Xcode jobs"
                    case 1: "An Xcode job runs"
                    case let count?: "\(count) Xcode jobs run"
                    }
                    throw HostSettingsError(
                        "\(jobs) on the Mac. Restarting ends the jobs of its runners: wait for them, or pass --stop-jobs."
                    )
                }
            }
            try await HostControl.perform(.restart, host: host.host, mac: mac.mac)
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
        @OptionGroup var host: HostOption
        @OptionGroup var mac: MacOption

        func validate() throws {
            guard labels.isEmpty == none else {
                throw ValidationError("Name the labels, or pass --none to remove them all.")
            }
        }

        func run() async throws { try await HostControl.perform(.saveRunnerLabels(labels), host: host.host, mac: mac.mac) }
    }

    static var unexpectedAnswer: HostSettingsError {
        HostSettingsError("The host answered with something else than what the command asked for.")
    }

    /// Sends a host a request and prints its answer.
    @MainActor static func perform(_ request: HostLinkRequest, on host: String? = nil) async throws {
        switch try await reply(to: request, on: host) {
        case .settings(let report): try write(report)
        case .github(let report): try write(report)
        default: throw unexpectedAnswer
        }
    }

    /// Reads or changes the settings of a host, or of a Mac that it manages, and prints them.
    @MainActor static func perform(_ request: HostSettingsRequest, host: String?, mac: String?) async throws {
        guard let mac else { return try await perform(.settings(request), on: host) }
        try write(try await managed(mac, on: host) { id in
            switch request {
            case .read: .read(refreshing: id)
            case .configurePool(let changes): .configurePool(changes, mac: id)
            case .saveStorage(let directory): .saveStorage(directory: directory, mac: id)
            case .saveXcode(let developerDirectory): .saveXcode(developerDirectory: developerDirectory, mac: id)
            case .saveRunnerLabels(let labels): .saveRunnerLabels(labels, mac: id)
            case .setPaused(let isPaused): .setPaused(isPaused, mac: id)
            case .restart: .restart(mac: id)
            }
        })
    }

    /// Reads the settings of a host, or the ones that the host last read from a Mac that it manages.
    @MainActor static func settings(host: String?, mac: String?) async throws -> HostSettingsReport? {
        if let mac { return try await managed(mac, on: host) { .read(refreshing: $0) }.settings }
        guard case .settings(let report) = try await reply(to: .settings(.read), on: host) else { throw unexpectedAnswer }
        return report
    }

    /// Asks a host about the Macs that it manages, or to change them, as a dashboard does.
    @MainActor static func macs(
        _ request: ManagedMacsRequest, on host: String?,
        over bridge: (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = HostSettingsBridge.request
    ) async throws -> ManagedMacsReport {
        guard case .macs(let report) = try await reply(to: .macs(request), on: host, over: bridge) else { throw unexpectedAnswer }
        return report
    }

    /// Has a host pair with a Mac that waits for a managing host, as a dashboard does through the host, with the
    /// Mac's code compared in place of a person comparing the two.
    ///
    /// - Parameters:
    ///   - bridge: Sends the requests to the host on this Mac. Tests pass a connection to a host of their own.
    ///   - showCode: Called with the host's code once the Macs exchanged keys.
    ///   - otherCode: Returns the code that the Mac shows. The host ends the pairing if it differs. It is not waited
    ///     for once the Mac refused or left.
    /// - Returns: The host's Macs after the pairing, with the Mac that it added.
    @MainActor static func pairManagedMac(
        named mac: String, on host: String?, timeout: Duration,
        over bridge: (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = HostSettingsBridge.request,
        showCode: (PairedMacs.CodeConfirmation) throws -> Void, otherCode: @escaping @MainActor () async throws -> String
    ) async throws -> ManagedMacsReport {
        // The host lists the Macs that wait to pair while it is asked for them.
        let deadline = ContinuousClock.now + timeout
        var found: WaitingMac?
        while found == nil {
            let report = try await macs(.discover, on: host, over: bridge)
            guard report.canAddMacs else {
                throw HostSettingsError("The host is managed by another Mac, so it cannot manage one itself.")
            }
            let named = report.waitingMacs.filter { $0.name == mac }
            guard named.count <= 1 else {
                throw HostSettingsError("\(named.count) Macs named \(mac) wait to pair. Rename one, or pair in the window.")
            }
            found = named.first
            if found == nil {
                guard ContinuousClock.now < deadline else {
                    throw HostSettingsError(
                        report.discoveryMessage ?? "No Mac named \(mac) waits for a managing host on the local network."
                    )
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        guard let found else { throw unexpectedAnswer }
        // The host tells the pairings that it runs for dashboards and commands apart by this name.
        let attempt = UUID()
        do {
            var report = try await macs(.pair(waitingMac: found.id, attempt: attempt), on: host, over: bridge)
            func paired() throws -> Bool {
                guard report.pairingAttempt == attempt else {
                    throw HostSettingsError("The host started another pairing in place of this one.")
                }
                if let error = report.pairingError { throw HostSettingsError(error) }
                return report.pairedMac != nil
            }
            while try !paired(), report.codeConfirmation == nil {
                try await Task.sleep(for: .milliseconds(200))
                report = try await macs(.read(refreshing: nil), on: host, over: bridge)
            }
            guard let shown = report.codeConfirmation else { return report }
            try showCode(shown)
            // The Mac can refuse or leave while its code is awaited, which the host's reads then show.
            final class Outcome { var result: Result<String, any Error>? }
            let other = Outcome()
            let reading = Task {
                do { other.result = .success(try await otherCode()) } catch { other.result = .failure(error) }
            }
            defer { reading.cancel() }
            while other.result == nil {
                try await Task.sleep(for: .milliseconds(200))
                report = try await macs(.read(refreshing: nil), on: host, over: bridge)
                _ = try paired()
            }
            guard let code = try other.result?.get(), code == shown.code else {
                let code = (try? other.result?.get()) ?? ""
                throw HostSettingsError(
                    "\(shown.macName) shows the code \(code), and the host shows \(shown.code) for it. The Macs did not pair."
                )
            }
            report = try await macs(.confirmCode(attempt: attempt), on: host, over: bridge)
            while try !paired() {
                try await Task.sleep(for: .milliseconds(200))
                report = try await macs(.read(refreshing: nil), on: host, over: bridge)
            }
            return report
        } catch {
            // The host pairs with one Mac at a time, so a pairing that this command leaves is ended.
            _ = try? await macs(.cancelPairing(attempt: attempt), on: host, over: bridge)
            throw error
        }
    }

    /// Sends a host a request about a Mac that it manages, as a dashboard does through the host, and returns what
    /// the host then lists for the Mac.
    ///
    /// - Parameters:
    ///   - bridge: Sends the request to the host on this Mac. Tests pass a connection to a host of their own.
    ///   - request: Makes the request for the Mac's ID, which the host's list gives for its name.
    @MainActor static func managed(
        _ mac: String, on host: String?,
        over bridge: (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = HostSettingsBridge.request,
        _ request: (HostPairing.ID) -> ManagedMacsRequest
    ) async throws -> ManagedMacsReport.Mac {
        guard case .macs(let list) = try await reply(to: .macs(.read(refreshing: nil)), on: host, over: bridge) else {
            throw unexpectedAnswer
        }
        let named = list.macs.filter { $0.name == mac || $0.id.uuidString.caseInsensitiveCompare(mac) == .orderedSame }
        guard let match = named.first else {
            let listed = list.macs.map(\.name).sorted().joined(separator: ", ")
            throw HostSettingsError("The host manages no Mac named \(mac)." + (listed.isEmpty ? "" : " It manages \(listed)."))
        }
        guard named.count == 1 else {
            throw HostSettingsError("The host manages \(named.count) Macs named \(mac). Pass the ID of one.")
        }
        guard case .macs(let report) = try await reply(to: .macs(request(match.id)), on: host, over: bridge),
              let answered = report.macs.first(where: { $0.id == match.id }) else { throw unexpectedAnswer }
        return answered
    }

    /// Signs the host out or reloads its repositories, and prints its answer. The host reports what went wrong with
    /// GitHub or the Keychain in its answer, and clears that after either succeeds, so it is the command's failure.
    @MainActor static func change(_ request: GitHubRequest, on host: String?) async throws {
        guard case .github(let report) = try await reply(to: .github(request), on: host) else { throw unexpectedAnswer }
        try write(report)
        if let error = report.errorMessage { throw HostSettingsError(error) }
    }

    /// Reads the host's GitHub sign-in, repositories, and runners.
    @MainActor static func github(on host: String?) async throws -> GitHubReport {
        guard case .github(let report) = try await reply(to: .github(.read), on: host) else { throw unexpectedAnswer }
        return report
    }

    /// Whether the installer set up a host on this Mac. Without one the app is a dashboard.
    @MainActor static var runsHost: Bool {
        guard let label = Bundle.main.bundleIdentifier else { return false }
        return hasInstalledHost(label, in: HostInstallation())
    }

    /// The hosts that this Mac's dashboard shows, from the Keychain item that the app keeps them in.
    @MainActor static func dashboardHosts() -> PairedMacs {
        PairedMacs(
            store: KeychainSecretStore.dashboardHosts(hostRoot: HostInstallation().hostRoot), name: HostPane.macName,
            role: .dashboard
        )
    }

    /// Posted when a command changed the hosts of this Mac's dashboard, for a dashboard that is open to read them
    /// again.
    static let dashboardHostsChangedNotification = Notification.Name("lynnpd.xcodehomerunner.dashboard-hosts-changed")

    static func dashboardHostsChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            dashboardHostsChangedNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
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

    /// Sends a host a request and returns its answer. Throws the host's reason when it refuses.
    ///
    /// - Parameters:
    ///   - host: A host that this Mac's dashboard shows, which gets the request over the Macs' pairing. `nil` for the
    ///     host on this Mac, which gets it over its settings service.
    ///   - bridge: Sends the request to the host on this Mac. Tests pass a connection to a host of their own.
    @MainActor static func reply(
        to request: HostLinkRequest, on host: String? = nil,
        over bridge: (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = HostSettingsBridge.request
    ) async throws -> HostLinkReply {
        let reply: HostLinkReply
        if let host {
            let paired = try RemoteOperationClient.host(named: host, installation: HostInstallation())
            reply = try await HostLink.send(
                request, to: try await RemoteOperationClient.find(paired), key: paired.pairing.symmetricKey,
                identity: paired.id.uuidString, timeout: request.replyTimeout
            )
        } else {
            let response = try await bridge(.link(JSONEncoder().encode(request)))
            if let error = response.error { throw HostSettingsError(error) }
            guard let data = response.reply else {
                throw HostSettingsError("The host that runs on this Mac does not take this command. Update it and try again.")
            }
            reply = try JSONDecoder().decode(HostLinkReply.self, from: data)
        }
        if case .refused(let reason) = reply { throw HostSettingsError(reason) }
        return reply
    }
}

extension PairingRole: ExpressibleByArgument {}

/// The host that a command reads or changes.
struct HostOption: ParsableArguments {
    @Option(help: "A host that this Mac's dashboard shows, by its name. Without it, the host on this Mac.")
    var host: String?
}

/// The Mac that a command reads or changes through its host.
struct MacOption: ParsableArguments {
    @Option(help: "A Mac that the host manages, by its name or ID. Without it, the host itself.")
    var mac: String?
}
