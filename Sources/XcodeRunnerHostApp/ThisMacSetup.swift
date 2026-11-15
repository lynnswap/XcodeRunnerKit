import Foundation
import Observation
import Subprocess
import XcodeRunnerHostSupport

/// Makes this Mac, which only shows a dashboard, a runner of a host that the dashboard shows: it installs the host
/// from this app, has it wait for a managing host, and allows the pairing that the sheet starts.
@MainActor @Observable
final class ThisMacSetup {
    enum Phase: Equatable {
        /// This Mac has no host, and the sheet offers to set one up.
        case offered
        case installing
        /// The host on this Mac waits for a managing host, so the sheet lists this Mac.
        case waiting
        /// The host on this Mac stopped waiting before a host paired with it.
        case ended
        /// A host manages this Mac.
        case managed
        case failed(String)
    }

    /// The setup that a sheet offered since the app opened. A sheet that opens later shows the same one, so that it
    /// neither installs the host again nor asks a host that waits to wait.
    private static var started: ThisMacSetup?
    /// Whether the host is installed, by this setup.
    private var isInstalled = false

    private(set) var phase: Phase
    @ObservationIgnored private var watching: Task<Void, Never>?
    private let install: @MainActor () async throws -> Void
    private let pairing: @MainActor (HostPairingRequest) async throws -> HostPairingReport
    private let hasHost: @MainActor () -> Bool

    /// - Parameters:
    ///   - install: Installs the host on this Mac and starts it.
    ///   - pairing: Asks this Mac's host about its pairings, or to change them.
    ///   - hasHost: Whether this Mac has a host now, which the person can have installed since the sheet offered to.
    init(
        install: @escaping @MainActor () async throws -> Void = ThisMacSetup.runInstaller,
        pairing: @escaping @MainActor (HostPairingRequest) async throws -> HostPairingReport = { try await HostControl.pairing($0) },
        hasHost: @escaping @MainActor () -> Bool = { HostControl.runsHost }
    ) {
        self.install = install
        self.pairing = pairing
        self.hasHost = hasHost
        phase = .offered
    }

    /// The setup for a sheet that pairs a Mac for a host to manage, on a Mac that has no host yet. `nil` on a Mac
    /// with a host, which pairs from its own settings.
    static func forSheet(role: PairingRole) -> ThisMacSetup? {
        guard role == .manager else { return nil }
        if let started { return started }
        guard !HostControl.runsHost, installer != nil else { return nil }
        let setup = ThisMacSetup()
        started = setup
        return setup
    }

    /// The installer in this app.
    private static var installer: URL? {
        let script = Bundle.main.resourceURL?.appending(path: "HostSetup/install-runner-host.sh")
        return script.flatMap { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) ? $0 : nil }
    }

    /// Installs the host and has it wait for a managing host.
    func start() {
        switch phase {
        case .installing, .waiting, .managed: return
        case .offered, .failed, .ended: break
        }
        phase = .installing
        Task {
            do {
                // Installing again would stop a host that runs, with its jobs.
                if !isInstalled, !hasHost() { try await install() }
                isInstalled = true
                try await waitForManager()
                phase = .waiting
                watchWait()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Notices when the host stops waiting without a pairing, as after five minutes, so that the sheet offers to
    /// have it wait again.
    private func watchWait() {
        watching?.cancel()
        watching = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.phase == .waiting else { return }
                guard let report = try? await self.pairing(.read) else { continue }
                if report.manager != nil {
                    self.phase = .managed
                    return
                }
                if report.window == nil {
                    self.phase = .ended
                    return
                }
            }
        }
    }

    /// Shows what the host that this setup installed does now, for a sheet that opens after the pairing or after
    /// the management ended.
    func refresh() async {
        guard isInstalled, phase != .installing, let report = try? await pairing(.read) else { return }
        if report.manager != nil {
            phase = .managed
        } else if report.window?.role == .manager {
            if phase != .waiting {
                phase = .waiting
                watchWait()
            }
        } else {
            phase = .ended
        }
    }

    /// Has the host wait for a managing host. The host that launchd just started takes a moment to answer.
    private func waitForManager() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            do {
                _ = try await pairing(.allow(.manager))
                return
            } catch {
                guard ContinuousClock.now < deadline else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Allows the pairing on this Mac's host if it shows `code`, the code that the sheet shows for the host that
    /// pairs. The person compared nothing by eye, because both codes are on this Mac.
    func allowPairing(showing code: String) async throws {
        guard phase == .waiting else { return }
        // The host shows its code a moment after the sheet shows the other one.
        let deadline = ContinuousClock.now + .seconds(15)
        while try await pairing(.read).window?.code == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
        }
        _ = try await pairing(.confirm(code: code))
    }

    /// Runs the installer in this app, which copies the app to the person's Applications folder, writes the host's
    /// LaunchAgent, and starts the host. It needs no administrator.
    static func runInstaller() async throws {
        guard let installer else { throw HostSettingsError("This copy of XcodeHomeRunner has no installer.") }
        let result = try await Subprocess.run(
            .path("/bin/bash"),
            arguments: [installer.path(percentEncoded: false), Bundle.main.bundleURL.path(percentEncoded: false)],
            output: .discarded, error: .string(limit: 8192)
        )
        guard result.terminationStatus.isSuccess else {
            let reason = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostSettingsError("The installer failed\(reason.isEmpty ? "." : ": \(reason)")")
        }
    }
}
