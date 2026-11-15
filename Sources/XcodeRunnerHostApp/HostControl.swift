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
        subcommands: [Status.self, Pause.self, Resume.self, Restart.self, Labels.self]
    )

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
            abstract: "Stop the host and start it again. It waits for the jobs that run."
        )

        func run() async throws { try await HostControl.perform(.settings(.restart)) }
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

    /// Sends this Mac's host a request and prints its answer.
    @MainActor static func perform(_ request: HostLinkRequest) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let answer: Data = switch try await reply(to: request) {
        case .settings(let report): try encoder.encode(report)
        default: throw HostSettingsError("The host answered with something else than what the command asked for.")
        }
        try FileHandle.standardOutput.write(contentsOf: answer + Data("\n".utf8))
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
