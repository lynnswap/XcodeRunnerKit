import AppKit
import ArgumentParser
import Darwin
import Foundation
import Observation
import Subprocess
import XcodeRunnerHostSupport
import XcodeRunnerKit

struct HostOptions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "XcodeHomeRunner",
        abstract: "Host opted-in GitHub Actions runners in a macOS menu bar app, or connect a dashboard to its host."
    )

    @Option(help: .hidden) var homeDirectory: String?
    /// Runs the menu bar host. The installed LaunchAgent passes this; opening the app without it shows a dashboard.
    @Flag(help: .hidden) var host = false
    @Flag(help: .hidden) var settingsService = false
    /// The embedded app has access to its pairing in the Keychain. The CLI needs only the managing host's ID.
    @Option(help: .hidden) var jobOptionsOwner: String?
    @Option(help: .hidden) var fetchPackage: String?
    @Option(help: .hidden) var packageManager: String?
    @Option(help: .hidden) var packageRoot: String?

    @Option(help: .hidden) var serviceDirectory: String?
    @Option(help: .hidden) var parentProcessID: Int32?
    @Option(help: .hidden) var ownershipDescriptor: Int32?
    @Option(help: .hidden) var jobSlotDescriptor: Int32?

    /// Sends the checkout through the dashboard's pairing, which belongs to the signed app.
    @Flag(help: .hidden) var runOnHost = false
    /// This Mac's folder for the operation's log and result bundle.
    @Option(help: .hidden) var outputDirectory: String?
    /// Reads or changes a host as `operation` says. `xcode-runner host` starts the app with this for the commands that
    /// send a host what its window sends it.
    @Flag(help: .hidden) var control = false
    /// An `xcode-runner` command and its options, after `--`.
    @Argument(parsing: .postTerminator, help: .hidden) var operation: [String] = []

    var installation: HostInstallation {
        HostInstallation(homeDirectory: homeDirectory.map { URL(filePath: $0) } ?? HostInstallation.defaultHomeDirectory)
    }

    /// The arguments for the options above. AppKit reads the others itself as user defaults, each a name with one
    /// dash and its value, such as the `-NSDocumentRevisionsDebugMode YES` that Xcode adds when it runs the app.
    static func ownArguments(in arguments: [String]) -> [String] {
        var own: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            // What follows the terminator is the operation, with its own options.
            if argument == "--" { return own + arguments[index...] }
            if argument.hasPrefix("-"), !argument.hasPrefix("--") {
                index += 2
            } else {
                own.append(argument)
                index += 1
            }
        }
        return own
    }

    func validate() throws {
        // A LaunchAgent written before dashboards passes only this flag. Starting a dashboard for it would leave the
        // Mac's runners stopped without an error.
        if settingsService && !host {
            throw ValidationError("--settings-service requires --host. Run the installer in this app to update the LaunchAgent.")
        }
        if control {
            guard !runOnHost, outputDirectory == nil, !operation.isEmpty else {
                throw ValidationError("--control takes a command after -- and neither --run-on-host nor --output-directory.")
            }
        } else if runOnHost != !operation.isEmpty || runOnHost != (outputDirectory != nil) {
            throw ValidationError("--run-on-host requires --output-directory and a command after --.")
        }
    }
}

/// The host app's entry point. The app target calls `main()` from its `main.swift`.
public enum RunnerHostApplication {
    /// Runs the menu bar host when launched with `--host`, a runner service helper when launched with
    /// `--service-directory`, a build or test on another Mac's host when launched with `--run-on-host`, and a command
    /// that reads or changes a host when launched with `--control`. Opened without them, the app starts the host that
    /// the installer set up on this Mac, or opens the dashboard for its paired host when this Mac has none.
    @MainActor public static func main() {
        main(authorization: nil, transport: { try await URLSession.shared.data(for: $0) })
    }

    package typealias Authorization = @MainActor @Sendable (Int, GitHubRunnerAccess) async throws -> GitHubRunnerScaleSet.Grant?
    package typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    @MainActor package static func main(authorization: Authorization?, transport: @escaping Transport) {
        do {
            let options = try HostOptions.parse(HostOptions.ownArguments(in: Array(CommandLine.arguments.dropFirst())))
            if let json = options.fetchPackage {
                guard let id = options.packageManager, let manager = UUID(uuidString: id), let root = options.packageRoot else {
                    throw ValidationError("A package fetch requires its managing host and installation.")
                }
                let fetch = try JSONDecoder().decode(PackageFetch.self, from: Data(json.utf8))
                Task {
                    do {
                        try await fetch.run(manager: manager, root: URL(filePath: root), input: .standardInput, output: .standardOutput)
                        Darwin.exit(EXIT_SUCCESS)
                    } catch { HostOptions.exit(withError: error) }
                }
                dispatchMain()
            }
            if let root = options.jobOptionsOwner {
                let store = KeychainSecretStore.managingHost(hostRoot: URL(filePath: root))
                let pairing = try store.read().map { try JSONDecoder().decode(HostManagement.Record.self, from: $0) }
                try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(pairing?.manager?.id))
                return
            }
            if let directory = options.serviceDirectory {
                guard let parent = options.parentProcessID, let ownership = options.ownershipDescriptor,
                      let slot = options.jobSlotDescriptor, getpgrp() == getpid() else {
                    throw ValidationError("Service helpers require a parent PID, an ownership descriptor, and their own process group.")
                }
                guard fcntl(ownership, F_GETFD) >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let service = RunnerService(directory: URL(filePath: directory), parent: parent, ownership: ownership, slot: slot)
                service.start()
                withExtendedLifetime(service) { dispatchMain() }
            }
            if options.control {
                let command = Task {
                    // A command that fails prints why and ends the process itself.
                    await HostControl.main(options.operation)
                    Darwin.exit(EXIT_SUCCESS)
                }
                // An interrupted command ends what it started on the host, such as a pairing, before it exits.
                let signals = [SIGINT, SIGTERM].map { number in
                    signal(number, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                    source.setEventHandler {
                        command.cancel()
                        // A request that the host has not answered does not end with its task.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Darwin.exit(128 + number) }
                    }
                    source.resume()
                    return source
                }
                withExtendedLifetime(signals) { dispatchMain() }
            }
            let installation = options.installation
            if let outputDirectory = options.outputDirectory {
                let command = Task {
                    await RemoteOperationClient.run(
                        options.operation, installation: installation,
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
                    let dashboard = Dashboard(pairing: PairedMacs(
                        store: KeychainSecretStore.dashboardHost(hostRoot: installation.hostRoot), name: HostPane.macName,
                        role: .dashboard
                    ))
                    application.delegate = dashboard
                    withExtendedLifetime(dashboard) { application.run() }
                    return
                }
                // This Mac's host owns its runners, so opening the app starts it, as it did before dashboards. If
                // launchd cannot start its service, the host runs in this process without the settings service.
                if startInstalledHost(label) {
                    if options.homeDirectory == nil { Dashboard.retireLoginItemForHost() }
                    return
                }
            }
            if options.settingsService, options.homeDirectory == nil { Dashboard.retireLoginItemForHost() }
            let host = try RunnerHost(installation: installation, settingsService: options.settingsService, authorization: authorization, transport: transport)
            application.setActivationPolicy(.accessory)
            application.delegate = host
            withExtendedLifetime(host) { application.run() }
        } catch {
            HostOptions.exit(withError: error)
        }
    }
}

/// Whether the installer set up a host for this user, which it does by writing the host's LaunchAgent.
func hasInstalledHost(_ label: String, in installation: HostInstallation) -> Bool {
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
    mutating func inheritOwnership(_ descriptors: Int32...) {
        preSpawnProcessConfigurator = { _, actions in
            for descriptor in descriptors {
                let code = posix_spawn_file_actions_addinherit_np(&actions, descriptor)
                if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            }
        }
    }
}

@MainActor
private final class RunnerService {
    private let directory: URL
    private let parent: Int32
    private let ownership: Int32
    private let slot: Int32
    private var task: Task<Void, Never>?
    private var parentExit: (any DispatchSourceProcess)?
    private var signals: [any DispatchSourceSignal] = []

    init(directory: URL, parent: Int32, ownership: Int32, slot: Int32) {
        self.directory = directory
        self.parent = parent
        self.ownership = ownership
        self.slot = slot
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
            var status: Int32 = EXIT_FAILURE
            do {
                try Task.checkCancellation()
                var options = Subprocess.PlatformOptions()
                options.inheritOwnership(ownership, slot)
                options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(35))]
                let serviceOptions = options
                let directory = self.directory
                let result = try await HostExecutionPool.withGitHubJob(slot: slot) { job in
                    try await Subprocess.run(
                        .path("/bin/bash"),
                        arguments: .init([directory.appending(path: "runsvc.sh").path]),
                        environment: .inherit.updating(["ACTIONS_RUNNER_SVC": "1", "XCODE_RUNNER_GITHUB_JOB": .init(job)]),
                        workingDirectory: .init(directory.path(percentEncoded: false)),
                        platformOptions: serviceOptions,
                        output: .currentStandardOutput,
                        error: .currentStandardError
                    ).terminationStatus
                }
                if case .exited(let code) = result { status = code }
                print("Official runner service ended with \(result).")
            } catch {
                print("Official runner service ended: \(error)")
            }
            // The host reaps this helper and cleans its group. If the host died, this helper owns cleanup.
            fflush(nil)
            if getppid() != parent { kill(-getpgrp(), SIGKILL) }
            Darwin.exit(status)
        }
        // Cover the interval between spawning this helper and registering the exit notification.
        if getppid() != parent { task?.cancel() }
    }
}

/// Advertise each idle host slot to one scale set at a time. GitHub only reveals queued work to a
/// set advertising capacity, so rotate idle offers across repositories without holding a build slot.
@MainActor @Observable final class GitHubJobCapacity {
    private(set) var offered: Set<String> = []
    private var nextName: String?
    private var rotateAt = ContinuousClock.now

    func update(listening: [Int: [String]], freeSlots: Int, now: ContinuousClock.Instant = .now) {
        let repositories = listening.keys.sorted().map { listening[$0, default: []].sorted() }
        let names = (0..<(repositories.map(\.count).max() ?? 0)).flatMap { index in
            repositories.compactMap { $0.indices.contains(index) ? $0[index] : nil }
        }
        let count = min(max(0, freeSlots), names.count)
        if count == 0 { offered = []; return }
        if now < rotateAt, offered.count == count, offered.isSubset(of: names) { return }
        let index = nextName.flatMap { names.firstIndex(of: $0) } ?? 0
        let round = names[index...] + names[..<index]
        offered = Set(round.prefix(count))
        nextName = names[(index + count) % names.count]
        rotateAt = now.advanced(by: .seconds(6))
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
        let registration: RunnerDirectory.JobRegistration
        var state: RunnerServiceState
        var problem: String?
    }
    private var runners: [URL: HostedRunner] = [:]
    private var serviceGroups: [String: Int32] = [:]
    private let githubCapacity = GitHubJobCapacity()
    private let authorization: RunnerHostApplication.Authorization
    private let transport: RunnerHostApplication.Transport
    private let settings: HostSettingsModel
    private var settingsServer: HostSettingsServer?
    private var statusItem: NSStatusItem?
    private var poolMenuItem: NSMenuItem?
    private var settingsWindow: NSWindowController?
    /// A dashboard Mac can also be a managed runner. Its local runner settings are accessible in their own window.
    private let dashboardPairing: PairedMacs
    private var dashboardWindow: NSWindowController?
    private var dashboardItem: NSMenuItem?
    private var monitoring: Task<Void, Never>?
    private var poolMonitoring: Task<Void, Never>?
    private var simulatorMaintenance: Task<Void, Never>?
    private var resourceMonitoring: Task<Void, Never>?
    private var githubMonitoring: Task<Void, Never>?
    private var storagePreparation: Task<Void, Never>?
    private var signals: [any DispatchSourceSignal] = []
    private var stopping = false
    private var restartsAfterStopping = false
    private var stopped = false
    private var terminationReplyPending = false

    init(installation: HostInstallation, settingsService: Bool, authorization: RunnerHostApplication.Authorization?, transport: @escaping RunnerHostApplication.Transport) throws {
        let root = installation.runnersRoot
        let logs = installation.logsDirectory
        self.root = root.resolvingSymlinksInPath()
        self.logs = logs
        self.installation = installation
        let settings = HostSettingsModel(installation: installation)
        self.settings = settings
        self.transport = transport
        self.authorization = authorization ?? { id, access in
            switch try await settings.github.runnerAdmission(repositoryID: id, access: access) {
            case .runnerGrant(let grant): return grant
            case .completed where access != .connect: return nil
            default: throw HostLinkError.unexpectedReply
            }
        }
        dashboardPairing = PairedMacs(
            store: KeychainSecretStore.dashboardHost(hostRoot: installation.hostRoot), name: HostPane.macName, role: .dashboard
        )
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
        settings.github.enablePackageAccess(on: installation)
        if settingsService {
            settingsServer = HostSettingsServer(settings: settings)
            // Only the installed LaunchAgent starts the host with its settings service, and launchd starts that host
            // again after it exits unsuccessfully.
            settings.restartHost = { [weak self] in
                guard let self else { return }
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
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(dashboardHostChanged(_:)), name: HostControl.dashboardHostChangedNotification,
            object: nil
        )
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
                await settings.github.preparePackageAccess()
                try Task.checkCancellation()
                let storage = try await installation.waitForStorageForLaunch { @MainActor error in
                    guard !Task.isCancelled else { return }
                    if self.settings.hostState != .waitingForStorage {
                        print("Waiting for runner storage: \(error)")
                    }
                    self.settings.storageDidBecomeUnavailable(error)
                }
                try Task.checkCancellation()
                environment = installation.environment(for: storage, hostExecutable: executable)
                settings.storageDidBecomeAvailable(storage)
                settings.hostState = .running
                startRunnerMonitoring()
                await settings.github.restore()
                try Task.checkCancellation()
                githubMonitoring = Task {
                    while !Task.isCancelled {
                        await settings.github.preparePackageAccess()
                        guard !Task.isCancelled else { break }
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
        resourceMonitoring = Task {
            while !Task.isCancelled {
                settings.sampleResources()
                do { try await Task.sleep(for: RunnerMetricSampler.interval) } catch { return }
            }
        }
        simulatorMaintenance = Task {
            await settings.configureDefaultPool()
            while !Task.isCancelled {
                await settings.trimSimulatorPool()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        poolMonitoring = Task {
            while !Task.isCancelled {
                await settings.refreshPoolStatus()
                var listening: [Int: [String]] = [:]
                for runner in runners.values where runner.state == .listening {
                    listening[runner.registration.repositoryID, default: []].append(runner.registration.name)
                }
                let freeSlots: Int
                if let status = settings.poolStatus, !settings.isPaused, status.waitingJobCount == 0 {
                    freeSlots = status.configuration.maximumConcurrentJobs - status.activeJobCount
                } else { freeSlots = 0 }
                githubCapacity.update(listening: listening, freeSlots: freeSlots)
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
        let dashboard = NSMenuItem(title: "Open Dashboard…", action: #selector(showDashboard(_:)), keyEquivalent: "")
        dashboard.target = self
        dashboard.isHidden = !canOpenDashboard
        dashboardItem = dashboard
        menu.addItem(dashboard)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit XcodeHomeRunner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        poolMenuItem = poolItem
    }

    // A Mac with an existing dashboard pairing can still use or disconnect it after upgrading.
    private var canOpenDashboard: Bool { settings.management.manager != nil || !dashboardPairing.macs.isEmpty }

    private func updatePoolMenuItem() {
        dashboardItem?.isHidden = !canOpenDashboard
        if let status = settings.poolStatus {
            poolMenuItem?.title = "\(status.activeJobCount) running · Limit \(status.configuration.maximumConcurrentJobs)"
        } else {
            poolMenuItem?.title = settings.poolError == nil ? "Execution pool not configured" : "Execution pool unavailable"
        }
    }

    /// Shows settings for this Mac and its runners.
    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = makeHostWindowController(settings: settings) }
        NSApplication.shared.activate()
        settingsWindow?.showWindow(nil)
    }

    @objc private func showDashboard(_ sender: Any?) {
        guard canOpenDashboard else { return }
        if dashboardWindow == nil {
            dashboardPairing.reload()
            dashboardPairing.start()
            dashboardWindow = makePaneWindowController(
                content: DashboardSplitViewController(model: DashboardWindowModel(pairing: dashboardPairing)) { [settings] in
                    settings.management.manager != nil
                },
                autosaveName: "XcodeHomeRunnerDashboard"
            )
        }
        NSApplication.shared.activate()
        dashboardWindow?.showWindow(nil)
    }

    @objc private func dashboardHostChanged(_ notification: Notification) {
        dashboardPairing.reload()
        updatePoolMenuItem()
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
        simulatorMaintenance?.cancel()
        resourceMonitoring?.cancel()
        githubMonitoring?.cancel()
        storagePreparation?.cancel()
        Task {
            for runner in runners.values { runner.task.cancel() }
            // Registration and management requests can both be waiting for a read from a managed Mac.
            async let stopManagedMacs: Void = settings.managedMacs.shutDown()
            await settings.github.shutDown()
            await settings.management.shutDown()
            await settings.managedMacsRelay.shutDown()
            await stopManagedMacs
            await dashboardPairing.shutDown()
            await storagePreparation?.value
            await monitoring?.value
            await poolMonitoring?.value
            await simulatorMaintenance?.value
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
        settings.refreshPause()
        let scan = try RunnerDirectory.scan(root)
        if let unreadable = scan.unreadable.first { throw unreadable.error }
        let removed = try scan.directories.filter { try $0.isRemoved() }
        let requested = try scan.directories.filter { try $0.isHosted() && $0.hasRegistration() && !removed.contains($0) }
        var registrations: [URL: RunnerDirectory.JobRegistration] = [:]
        var problems: [URL: String] = [:]
        for runner in requested {
            do { registrations[runner.url] = try runner.jobRegistration() }
            catch { problems[runner.url] = error.localizedDescription }
        }
        for (directory, runner) in runners where settings.isPaused || registrations[directory] != runner.registration || runner.state == .stopped {
            // A job includes checkout and post-job cleanup, even when Runner.Worker is not present yet.
            if settings.github.reservations.contains(directory) { continue }
            runner.task.cancel()
            await runner.task.value
            runners[directory] = nil
        }
        try Task.checkCancellation()
        // The service of a removed runner stopped above, so its folder is no longer in use.
        for directory in removed where runners[directory.url] == nil {
            try FileManager.default.removeItem(at: directory.url)
            print("Removed \(directory.name).")
        }
        // Read after the waits above, during which the Mac can be paused or resumed.
        let isPaused = settings.isPaused
        var individual: Set<URL> = []
        for runner in requested where runners[runner.url] == nil {
            if try runner.hasIndividualService() {
                if !isPaused { print("Skipped \(runner.name): uninstall its individual service before opting in.") }
                individual.insert(runner.url)
            } else if !isPaused, let registration = registrations[runner.url] {
                runners[runner.url] = HostedRunner(task: Task { await listen(runner, registration: registration) }, registration: registration, state: .starting)
            }
        }
        settings.runnerScanError = nil
        settings.runners = requested.sorted { $0.name < $1.name }.map { runner in
            let state: RunnerServiceState = if isPaused, settings.github.reservations.contains(runner.url) {
                .finishing
            } else if problems[runner.url] != nil {
                .failed
            } else if let hosted = runners[runner.url] {
                hosted.state
            } else {
                individual.contains(runner.url) ? .individualService : (isPaused ? .paused : .starting)
            }
            var problem = problems[runner.url] ?? runners[runner.url]?.problem
            if state == .starting, registrations[runner.url] == nil, settings.management.manager != nil {
                problem = "Waiting for GitHub runner configuration. Update the managing host to a version that supports job reservations."
            }
            return RunnerSettingsRow.read(runner, state: state, problem: problem)
        }
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

    private func listen(_ directory: RunnerDirectory, registration: RunnerDirectory.JobRegistration) async {
        while !Task.isCancelled && !settings.isPaused {
            do {
                struct WorkSettings: Decodable { let workFolder: String }
                let work = try directory.registration(as: WorkSettings.self).workFolder
                let workFolder = URL(filePath: work, relativeTo: directory.url).standardizedFileURL.path(percentEncoded: false)
                let renew: @MainActor @Sendable () async throws -> GitHubRunnerScaleSet.Grant = {
                    guard let grant = try await self.authorization(registration.repositoryID, .connect) else {
                        throw HostLinkError.unexpectedReply
                    }
                    return grant
                }
                let grant = try await renew()
                let name = registration.name
                let set: GitHubRunnerScaleSet
                do {
                    // Unlinking must drain an in-flight creation before looking up and deleting its scale set.
                    try Task.checkCancellation()
                    try settings.github.reservations.begin(directory, installation: installation)
                    defer { settings.github.reservations.finish(directory.url) }
                    set = try await GitHubRunnerScaleSet.connect(grant: grant, name: name, labels: registration.labels,
                                                               owner: name, sessionFile: directory.url.appending(path: ".xcode-home-runner-session.json"),
                                                               renewGrant: renew, transport: transport)
                }
                runners[directory.url]?.state = .listening
                runners[directory.url]?.problem = nil
                do {
                    try await set.listen(pool: settings.pool, hasCapacity: {
                        self.githubCapacity.offered.contains(name)
                    }, workerIsRunning: {
                        guard let group = self.serviceGroups[directory.name] else { return false }
                        return try Self.jobWorker(inGroup: group) != nil
                    }, whileAuthorized: { access in
                        try Task.checkCancellation()
                        guard !self.installation.isPaused(), try !directory.isRemoved(),
                              try directory.unregisteringRepository() == nil else { throw CancellationError() }
                        _ = try await self.authorization(registration.repositoryID, access)
                        try Task.checkCancellation()
                    }, begin: {
                        guard try directory.jobRegistration() == registration else { throw CancellationError() }
                        try self.settings.github.reservations.begin(directory, installation: self.installation)
                        self.runners[directory.url]?.state = .running
                    }, finish: {
                        self.settings.github.reservations.finish(directory.url)
                        self.runners[directory.url]?.state = .listening
                    }, run: { slot, registered in
                        let configuration = try await set.configuration(name: name, workFolder: workFolder)
                        registered(configuration.runner.id)
                        do { try await self.serve(directory.url, configuration: configuration.encodedJITConfig, slot: slot) }
                        catch {
                            let original = error
                            do { try await Task { try await set.removeRunner(configuration.runner.id) }.value }
                            catch { throw HostSettingsError("\(original.localizedDescription) Could not remove the GitHub job runner: \(error.localizedDescription)") }
                            throw original
                        }
                        try await set.removeRunner(configuration.runner.id)
                    })
                } catch {
                    let original = error
                    do { try await Task { try await set.close() }.value }
                    catch { print("Could not close the GitHub session for \(directory.name): \(error.localizedDescription)") }
                    throw original
                }
                try await set.close()
            } catch {
                if Task.isCancelled || settings.isPaused { break }
                if runners[directory.url]?.state != .failed {
                    print("Could not take GitHub jobs for \(directory.name): \(error.localizedDescription)")
                }
                runners[directory.url]?.state = .failed
                runners[directory.url]?.problem = error.localizedDescription
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        runners[directory.url]?.state = .stopped
    }

    private func serve(_ directory: URL, configuration: String, slot: Int32) async throws {
        let runtime = try await Self.jobRuntime(in: directory)
        try await launchJob(runtime, name: directory.lastPathComponent, configuration: configuration, slot: slot)
    }

    /// The official run script keeps its self-updates here. JIT credentials must never replace the registration
    /// that the managing host uses to identify this work directory.
    @concurrent private static func jobRuntime(in directory: URL) async throws -> URL {
        let files = FileManager.default
        let runtime = directory.appending(path: ".xcode-home-runner-job")
        if !files.fileExists(atPath: runtime.path) {
            let staging = directory.appending(path: ".xcode-home-runner-installing")
            if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
            try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                for component in ["bin", "externals"] {
                    try Task.checkCancellation()
                    let source = directory.appending(path: component).resolvingSymlinksInPath()
                    try files.copyItem(at: source, to: staging.appending(path: component))
                }
                try files.copyItem(at: staging.appending(path: "bin/runsvc.sh"), to: staging.appending(path: "runsvc.sh"))
                try files.moveItem(at: staging, to: runtime)
            } catch {
                let original = error
                do { try files.removeItem(at: staging) }
                catch { throw HostSettingsError("\(original.localizedDescription) Could not clean up the runner installation: \(error.localizedDescription)") }
                throw original
            }
        }
        for name in [".path", ".env"] {
            let target = runtime.appending(path: name)
            do { try Data(contentsOf: directory.appending(path: name)).write(to: target, options: .atomic) }
            catch CocoaError.fileReadNoSuchFile {
                do { try files.removeItem(at: target) } catch CocoaError.fileNoSuchFile { }
            }
        }
        return runtime
    }

    private func launchJob(_ directory: URL, name: String, configuration: String, slot: Int32) async throws {
        let log = logs.appending(path: name + ".log")
        let descriptor = open(log.path(percentEncoded: false), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            print("Could not open log for \(name): \(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))).")
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        var options = Subprocess.PlatformOptions()
        // The official updater searches for its Node process by the service's process group.
        options.processGroupID = 0
        // Helpers retain this same open-file lock until their services finish shutting down.
        options.inheritOwnership(lockDescriptor, slot)
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(50))]
        var jobEnvironment = environment
        jobEnvironment["ACTIONS_RUNNER_INPUT_JITCONFIG"] = configuration
        defer { serviceGroups[name] = nil }
        let result = try await Subprocess.run(
            .path(.init(executable.path(percentEncoded: false))),
            arguments: .init([
                "--service-directory", directory.path(percentEncoded: false),
                "--parent-process-id", String(getpid()),
                "--ownership-descriptor", String(lockDescriptor),
                "--job-slot-descriptor", String(slot),
            ]),
            environment: .inherit.updating(Dictionary(uniqueKeysWithValues: jobEnvironment.map {
                (Subprocess.Environment.Key(stringLiteral: $0.key), Optional($0.value))
            })),
            workingDirectory: .init(directory.path(percentEncoded: false)),
            platformOptions: options,
            input: .none,
            output: .fileDescriptor(.init(rawValue: descriptor), closeAfterSpawningProcess: false),
            error: .fileDescriptor(.init(rawValue: descriptor), closeAfterSpawningProcess: false)
        ) { execution in
            let group = execution.processIdentifier.value
            self.serviceGroups[name] = group
            try await Self.cleanUpServiceGroupAfterExit(group)
        }
        guard result.terminationStatus == .exited(0) else {
            throw HostSettingsError("GitHub runner \(name) ended with \(result.terminationStatus). See \(log.path).")
        }
    }
}
