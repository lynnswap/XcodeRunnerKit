import AppKit
import ArgumentParser
import Darwin
import Foundation
import Subprocess
import XcodeRunnerHostSupport
import XcodeRunnerKit

struct HostOptions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "XcodeHomeRunner",
        abstract: "Host opted-in GitHub Actions runners in a macOS menu bar app, or show hosts on other Macs."
    )

    @Option(help: .hidden) var homeDirectory: String?
    /// Runs the menu bar host. The installed LaunchAgent passes this; opening the app without it shows a dashboard.
    @Flag(help: .hidden) var host = false
    @Flag(help: .hidden) var settingsService = false

    @Option(help: .hidden) var serviceDirectory: String?
    @Option(help: .hidden) var parentProcessID: Int32?
    @Option(help: .hidden) var ownershipDescriptor: Int32?

    /// The host that runs `operation`. `xcode-runner` starts the app with this for its `--host` option, because macOS
    /// gives the pairings in the app's Keychain item to the app alone.
    @Option(help: .hidden) var runOnHost: String?
    /// This Mac's folder for the operation's log and result bundle.
    @Option(help: .hidden) var outputDirectory: String?
    /// An `xcode-runner` command and its options, after `--`.
    @Argument(parsing: .remaining, help: .hidden) var operation: [String] = []

    var installation: HostInstallation {
        HostInstallation(homeDirectory: homeDirectory.map { URL(filePath: $0) } ?? HostInstallation.defaultHomeDirectory)
    }

    func validate() throws {
        // A LaunchAgent written before dashboards passes only this flag. Starting a dashboard for it would leave the
        // Mac's runners stopped without an error.
        if settingsService && !host {
            throw ValidationError("--settings-service requires --host. Run the installer in this app to update the LaunchAgent.")
        }
        if (runOnHost == nil) != operation.isEmpty || (runOnHost == nil) != (outputDirectory == nil) {
            throw ValidationError("--run-on-host requires --output-directory and a command after --.")
        }
    }
}

/// The host app's entry point. The app target calls `main()` from its `main.swift`.
public enum RunnerHostApplication {
    /// Runs the menu bar host when launched with `--host`, a runner service helper when launched with
    /// `--service-directory`, and a build or test on another Mac's host when launched with `--run-on-host`. Opened
    /// without them, the app starts the host that the installer set up on this Mac, or shows a dashboard of hosts on
    /// other Macs when this Mac has none.
    @MainActor public static func main() {
        do {
            let options = try HostOptions.parse()
            if let directory = options.serviceDirectory {
                guard let parent = options.parentProcessID, let ownership = options.ownershipDescriptor,
                      getpgrp() == getpid() else {
                    throw ValidationError("Service helpers require a parent PID, an ownership descriptor, and their own process group.")
                }
                guard fcntl(ownership, F_GETFD) >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let service = RunnerService(directory: URL(filePath: directory), parent: parent, ownership: ownership)
                service.start()
                withExtendedLifetime(service) { dispatchMain() }
            }
            let installation = options.installation
            if let hostName = options.runOnHost, let outputDirectory = options.outputDirectory {
                let command = Task {
                    await RemoteOperationClient.run(
                        options.operation, onHostNamed: hostName, installation: installation,
                        outputDirectory: URL(filePath: outputDirectory)
                    )
                }
                let signals = [SIGINT, SIGTERM].map { number in
                    signal(number, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                    source.setEventHandler { command.cancel() }
                    source.resume()
                    return source
                }
                Task { Darwin.exit(await command.value) }
                withExtendedLifetime(signals) { dispatchMain() }
            }
            let application = NSApplication.shared
            if !options.host {
                guard let label = Bundle.main.bundleIdentifier, hasInstalledHost(label, in: installation) else {
                    // Only the pairings are kept, in the Keychain: a dashboard creates nothing under the host's folders.
                    let dashboard = Dashboard(hosts: PairedMacs(
                        store: KeychainSecretStore.dashboardHosts(hostRoot: installation.hostRoot), name: HostPane.macName,
                        role: .dashboard
                    ))
                    application.setActivationPolicy(.regular)
                    application.delegate = dashboard
                    withExtendedLifetime(dashboard) { application.run() }
                    return
                }
                // This Mac's host owns its runners, so opening the app starts it, as it did before dashboards. If
                // launchd cannot start its service, the host runs in this process without the settings service.
                if startInstalledHost(label) { return }
            }
            let host = try RunnerHost(installation: installation, settingsService: options.settingsService)
            application.setActivationPolicy(.accessory)
            application.delegate = host
            withExtendedLifetime(host) { application.run() }
        } catch {
            HostOptions.exit(withError: error)
        }
    }
}

/// Whether the installer set up a host for this user, which it does by writing the host's LaunchAgent.
private func hasInstalledHost(_ label: String, in installation: HostInstallation) -> Bool {
    let agent = installation.homeDirectory.appending(path: "Library/LaunchAgents/\(label).plist")
    return FileManager.default.fileExists(atPath: agent.path(percentEncoded: false))
}

/// Asks launchd to start the installed host's service.
private func startInstalledHost(_ label: String) -> Bool {
    let launchctl = Process()
    launchctl.executableURL = URL(filePath: "/bin/launchctl")
    launchctl.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
    do { try launchctl.run() } catch { return false }
    launchctl.waitUntilExit()
    return launchctl.terminationStatus == 0
}

private extension Subprocess.PlatformOptions {
    mutating func inheritOwnership(_ descriptor: Int32) {
        preSpawnProcessConfigurator = { _, actions in
            let code = posix_spawn_file_actions_addinherit_np(&actions, descriptor)
            if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
    }
}

@MainActor
private final class RunnerService {
    private let directory: URL
    private let parent: Int32
    private let ownership: Int32
    private var task: Task<Void, Never>?
    private var parentExit: (any DispatchSourceProcess)?
    private var signals: [any DispatchSourceSignal] = []

    init(directory: URL, parent: Int32, ownership: Int32) {
        self.directory = directory
        self.parent = parent
        self.ownership = ownership
    }

    func start() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { self.task?.cancel() }
            source.resume()
            signals.append(source)
        }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler { self.task?.cancel() }
        source.resume()
        parentExit = source
        task = Task {
            do {
                try Task.checkCancellation()
                var options = Subprocess.PlatformOptions()
                options.inheritOwnership(ownership)
                options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(35))]
                let result = try await Subprocess.run(
                    .path("/bin/bash"),
                    arguments: .init([directory.appending(path: "runsvc.sh").path(percentEncoded: false)]),
                    environment: .inherit.updating(["ACTIONS_RUNNER_SVC": "1"]),
                    workingDirectory: .init(directory.path(percentEncoded: false)),
                    platformOptions: options,
                    output: .currentStandardOutput,
                    error: .currentStandardError
                )
                print("Official runner service ended with \(result.terminationStatus).")
            } catch {
                print("Official runner service ended: \(error)")
            }
            // This helper owns its group; remove any descendants left by the service wrapper.
            fflush(nil)
            kill(-getpgrp(), SIGKILL)
            Darwin.exit(EXIT_FAILURE)
        }
        // Cover the interval between spawning this helper and registering the exit notification.
        if getppid() != parent { task?.cancel() }
    }
}

@MainActor
private final class RunnerHost: NSObject, NSApplicationDelegate {
    private let root: URL
    private let logs: URL
    private let lockDescriptor: Int32
    private let executable: URL
    private let installation: HostInstallation
    private var environment: [String: String] = [:]
    private struct HostedRunner {
        let task: Task<Void, Never>
        var state: RunnerServiceState
        /// The process group of the runner's service, once it started.
        var processGroup: Int32?
        /// Stops the service of a paused runner when the worker of its job ends.
        var jobWatch: (worker: Int32, source: any DispatchSourceProcess)?
        /// Whether the service was asked to stop when its job ended while the Mac was paused.
        var stoppedAfterJob = false
    }
    private var runners: [URL: HostedRunner] = [:]
    private let settings: HostSettingsModel
    private var settingsServer: HostSettingsServer?
    private var statusItem: NSStatusItem?
    private var poolMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var monitoring: Task<Void, Never>?
    private var poolMonitoring: Task<Void, Never>?
    private var githubMonitoring: Task<Void, Never>?
    private var storagePreparation: Task<Void, Never>?
    private var signals: [any DispatchSourceSignal] = []
    private var stopping = false
    private var restartsAfterStopping = false
    private var stopped = false
    private var terminationReplyPending = false

    init(installation: HostInstallation, settingsService: Bool) throws {
        let root = installation.runnersRoot
        let logs = installation.logsDirectory
        self.root = root.resolvingSymlinksInPath()
        self.logs = logs
        self.installation = installation
        self.settings = HostSettingsModel(installation: installation)
        guard let executable = Bundle.main.executableURL else {
            throw ValidationError("Cannot locate the runner host executable.")
        }
        self.executable = executable
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        lockDescriptor = open(root.appending(path: ".xcode-runner-host.lock").path(percentEncoded: false),
                              O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(lockDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Another runner host already manages \(root.path(percentEncoded: false))."
            ])
        }
        super.init()
        if settingsService {
            settingsServer = HostSettingsServer(github: settings.github)
            // Only the installed LaunchAgent starts the host with its settings service, and launchd starts that host
            // again after it exits unsuccessfully.
            settings.restartHost = { [unowned self] in
                restartsAfterStopping = true
                beginShutdown()
            }
        }
    }

    deinit { close(lockDescriptor) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        settingsServer?.start()
        settings.management.start()
        settings.managedMacs.start()
        settings.hostState = .preparingStorage
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { self.beginShutdown() }
            source.resume()
            signals.append(source)
        }
        storagePreparation = Task {
            do {
                let storage = try await installation.waitForStorageForLaunch { @MainActor error in
                    guard !Task.isCancelled else { return }
                    if self.settings.hostState != .waitingForStorage {
                        print("Waiting for runner storage: \(error)")
                    }
                    self.settings.storageDidBecomeUnavailable(error)
                }
                try Task.checkCancellation()
                environment = installation.environment(for: storage)
                settings.storageDidBecomeAvailable(storage)
                settings.hostState = .running
                startRunnerMonitoring()
                await settings.github.restore()
                try Task.checkCancellation()
                githubMonitoring = Task {
                    while !Task.isCancelled {
                        if !settings.isSaving { await settings.github.synchronize() }
                        do { try await Task.sleep(for: .seconds(300)) }
                        catch { break }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                settings.storagePreparationFailed(error)
                print("Runner storage preparation failed: \(error)")
                showSettings(nil)
            }
        }
        poolMonitoring = Task {
            // Pool reads and writes can wait for another process's pool lock, so they stay out of runner startup.
            await settings.configureDefaultPool()
            while !Task.isCancelled {
                await settings.trimSimulatorPool()
                await settings.refreshPoolStatus()
                updatePoolMenuItem()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
        }
        print("Runner host started for \(root.path(percentEncoded: false)).")
    }

    private func startRunnerMonitoring() {
        monitoring = Task {
            while !Task.isCancelled {
                do {
                    try await reconcile()
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    break
                } catch {
                    print("Runner host scan failed: \(error)")
                    settings.runnerScanError = "Could not refresh runner services: \(error.localizedDescription)"
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { break }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "hammer.circle", accessibilityDescription: "XcodeHomeRunner")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "XcodeHomeRunner"
        let menu = NSMenu()
        let poolItem = NSMenuItem(title: "Checking execution pool…", action: nil, keyEquivalent: "")
        menu.addItem(poolItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit XcodeHomeRunner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        poolMenuItem = poolItem
    }

    private func updatePoolMenuItem() {
        if let status = settings.poolStatus {
            poolMenuItem?.title = "\(status.activeJobCount) running · Limit \(status.configuration.maximumConcurrentJobs)"
        } else {
            poolMenuItem?.title = settings.poolError == nil ? "Execution pool not configured" : "Execution pool unavailable"
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = makeHostWindow(settings: settings) }
        NSApplication.shared.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if stopped { return .terminateNow }
        terminationReplyPending = true
        beginShutdown()
        return .terminateLater
    }

    private func beginShutdown() {
        guard !stopping else { return }
        stopping = true
        settings.hostState = .stopping
        settingsServer?.stop()
        monitoring?.cancel()
        poolMonitoring?.cancel()
        githubMonitoring?.cancel()
        storagePreparation?.cancel()
        Task {
            for runner in runners.values { runner.task.cancel() }
            await settings.github.shutDown()
            await settings.management.shutDown()
            await settings.managedMacsRelay.shutDown()
            await settings.managedMacs.shutDown()
            await storagePreparation?.value
            await monitoring?.value
            await poolMonitoring?.value
            await githubMonitoring?.value
            for runner in runners.values { await runner.task.value }
            stopped = true
            if restartsAfterStopping {
                print("Runner host stopped to restart.")
                fflush(nil)
                Darwin.exit(EXIT_FAILURE)
            }
            print("Runner host stopped.")
            if terminationReplyPending {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func reconcile() async throws {
        let scan = try RunnerDirectory.scan(root)
        if let unreadable = scan.unreadable.first { throw unreadable.error }
        // A runner marked while the services below stop keeps running until the next scan stops it.
        let removed = try scan.directories.filter { try $0.isRemoved() }
        let requested = try scan.directories.filter { try $0.isHosted() && $0.hasRegistration() && !removed.contains($0) }
        let requestedURLs = Set(requested.map(\.url))
        for directory in runners.keys.filter({ !requestedURLs.contains($0) }) {
            let task = runners.removeValue(forKey: directory)?.task
            task?.cancel()
            await task?.value
        }
        try Task.checkCancellation()
        // The service of a removed runner stopped above, so its folder is no longer in use.
        for directory in removed {
            try FileManager.default.removeItem(at: directory.url)
            print("Removed \(directory.name).")
        }
        let isPaused = settings.isPaused
        // A paused host lets each runner finish the job that it runs, and stops the others. The official runner has
        // no way to refuse jobs while it runs, so a job that it takes in the instant before its service stops is
        // cancelled, as when the host quits.
        var finishing: Set<URL> = []
        // A service that stopped when its job ended is removed even if the Mac resumed since, so that it starts again.
        for (directory, runner) in runners where runner.stoppedAfterJob {
            runners[directory] = nil
            await runner.task.value
            print("Paused \(directory.lastPathComponent).")
        }
        if isPaused {
            var stopping: [(directory: URL, task: Task<Void, Never>)] = []
            for (directory, runner) in runners {
                // A service that just ended has no processes to list, and no job.
                if runner.state == .running, let group = runner.processGroup,
                   let worker = (try? Self.jobWorker(inGroup: group)) ?? nil {
                    finishing.insert(directory)
                    if runner.jobWatch?.worker != worker {
                        runner.jobWatch?.source.cancel()
                        runners[directory]?.jobWatch = (worker, stopService(of: directory, after: worker))
                    }
                    continue
                }
                runner.jobWatch?.source.cancel()
                runners[directory] = nil
                // Every idle runner is asked to stop before any of them is waited for, so none takes a job meanwhile.
                runner.task.cancel()
                stopping.append((directory, runner.task))
            }
            for runner in stopping {
                await runner.task.value
                print("Paused \(runner.directory.lastPathComponent).")
            }
            try Task.checkCancellation()
        }
        var individual: Set<URL> = []
        for runner in requested where runners[runner.url] == nil {
            if try runner.hasIndividualService() {
                if !isPaused { print("Skipped \(runner.name): uninstall its individual service before opting in.") }
                individual.insert(runner.url)
            } else if !isPaused {
                runners[runner.url] = HostedRunner(task: Task { await serve(runner.url) }, state: .starting)
            }
        }
        settings.runnerScanError = nil
        settings.runners = requested.sorted { $0.name < $1.name }.map { runner in
            let state: RunnerServiceState = if finishing.contains(runner.url) {
                .finishing
            } else if let hosted = runners[runner.url] {
                hosted.state
            } else {
                individual.contains(runner.url) ? .individualService : .paused
            }
            return RunnerSettingsRow.read(runner, state: state)
        }
    }

    /// Stops a paused runner's service as soon as its job's worker ends. A runner whose repository has jobs waiting
    /// takes the next one before the next scan of the runners.
    private func stopService(of directory: URL, after worker: Int32) -> any DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(identifier: worker, eventMask: .exit, queue: .main)
        source.setEventHandler {
            source.cancel()
            guard let runner = self.runners[directory], runner.jobWatch?.worker == worker else { return }
            self.runners[directory]?.jobWatch = nil
            // The Mac can have resumed while the job ran. The next scan removes a service that stops here.
            if self.settings.isPaused {
                self.runners[directory]?.stoppedAfterJob = true
                runner.task.cancel()
            }
        }
        source.resume()
        return source
    }

    /// The worker process that the official runner in a service's process group started for the job that it runs.
    private nonisolated static func jobWorker(inGroup identifier: Int32) throws -> Int32? {
        try groupMembers(identifier).first { member in
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            // A worker that ended stays listed until the runner collects its status.
            guard proc_pidinfo(member, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_status != UInt32(SZOMB) else {
                return false
            }
            return withUnsafeBytes(of: info.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "Runner.Worker"
        }
    }

    private nonisolated static func cleanUpServiceGroupAfterExit(_ identifier: Int32) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let source = DispatchSource.makeProcessSource(identifier: identifier, eventMask: .exit, queue: .global())
            source.setEventHandler {
                // Subprocess retains the zombie until this body returns, preventing PID/group reuse.
                let result = kill(-identifier, SIGKILL)
                let code = errno
                source.setEventHandler(handler: nil)
                source.cancel()
                do {
                    if result != 0 && code != ESRCH {
                        // macOS reports EPERM for a group containing only unreaped zombies.
                        if try code != EPERM || groupHasLiveProcesses(identifier) {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            source.resume()
        }
    }

    private nonisolated static func groupHasLiveProcesses(_ identifier: Int32) throws -> Bool {
        for member in try groupMembers(identifier) {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            let read = proc_pidinfo(member, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
            if read == size {
                if info.pbsi_pgid == UInt32(identifier) && info.pbsi_status != UInt32(SZOMB) { return true }
            } else if errno != ESRCH {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        return false
    }

    /// The processes in a process group, with those that already exited and were not reaped.
    private nonisolated static func groupMembers(_ identifier: Int32) throws -> [Int32] {
        let estimatedBytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(identifier), nil, 0)
        guard estimatedBytes > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var members = [Int32](repeating: 0, count: Int(estimatedBytes) / MemoryLayout<Int32>.stride)
        var count: Int32
        repeat {
            errno = 0
            count = members.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(identifier), $0.baseAddress, Int32($0.count))
            }
            guard count > 0 || errno == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if Int(count) < members.count * MemoryLayout<Int32>.stride { break }
            members += members
        } while true
        return Array(members.prefix(Int(count) / MemoryLayout<Int32>.stride))
    }

    private func serve(_ directory: URL) async {
        let name = directory.lastPathComponent
        let log = logs.appending(path: name + ".log")
        let descriptor = open(log.path(percentEncoded: false), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            print("Could not open log for \(name): \(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))).")
            runners[directory]?.state = .failed
            return
        }
        defer { close(descriptor) }
        var options = Subprocess.PlatformOptions()
        // The official updater searches for its Node process by the service's process group.
        options.processGroupID = 0
        // Helpers retain this same open-file lock until their services finish shutting down.
        options.inheritOwnership(lockDescriptor)
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(50))]
        do {
            print("Starting \(name); service log: \(log.path(percentEncoded: false)).")
            _ = try await Subprocess.run(
                .path(.init(executable.path(percentEncoded: false))),
                arguments: .init([
                    "--service-directory", directory.path(percentEncoded: false),
                    "--parent-process-id", String(getpid()),
                    "--ownership-descriptor", String(lockDescriptor),
                ]),
                environment: .inherit.updating(Dictionary(uniqueKeysWithValues: environment.map {
                    (Subprocess.Environment.Key(stringLiteral: $0.key), Optional($0.value))
                })),
                workingDirectory: .init(directory.path(percentEncoded: false)),
                platformOptions: options,
                input: .none,
                output: .fileDescriptor(.init(rawValue: descriptor), closeAfterSpawningProcess: false),
                error: .fileDescriptor(.init(rawValue: descriptor), closeAfterSpawningProcess: false)
            ) { execution in
                self.runners[directory]?.state = .running
                self.runners[directory]?.processGroup = execution.processIdentifier.value
                try await Self.cleanUpServiceGroupAfterExit(execution.processIdentifier.value)
            }
            if Task.isCancelled {
                print("\(name) service stopped.")
            } else {
                print("\(name) service stopped. Inspect its service log before restarting the host.")
            }
            runners[directory]?.state = .stopped
        } catch {
            print("\(name) service ended: \(error)")
            runners[directory]?.state = .failed
        }
    }
}
