import AppKit
import ArgumentParser
import Darwin
import Foundation
import Subprocess
import SwiftUI

struct HostOptions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-runner-host",
        abstract: "Host opted-in GitHub Actions runners in a macOS menu bar app."
    )

    @Option(help: "Directory containing runner installations.")
    var runnersRoot = URL.homeDirectory.appending(path: "Library/XcodeRunnerKit/runners").path(percentEncoded: false)

    @Option(help: "Directory containing the shared execution pool and compilation cache.")
    var hostRoot = URL.homeDirectory.appending(path: "Library/Application Support/XcodeRunnerKit").path(percentEncoded: false)

    @Option(help: .hidden) var serviceDirectory: String?
    @Option(help: .hidden) var parentProcessID: Int32?
    @Option(help: .hidden) var ownershipDescriptor: Int32?

    @Option(help: "Directory for runner service logs.")
    var logsDirectory = URL.homeDirectory.appending(path: "Library/Application Support/XcodeRunnerKit/logs/runners").path(percentEncoded: false)
}

@main
private enum RunnerHostApplication {
    @MainActor static func main() {
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
            let host = try RunnerHost(
                root: URL(filePath: options.runnersRoot, directoryHint: .isDirectory),
                logs: URL(filePath: options.logsDirectory, directoryHint: .isDirectory),
                hostRoot: URL(filePath: options.hostRoot, directoryHint: .isDirectory)
            )
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.delegate = host
            withExtendedLifetime(host) { application.run() }
        } catch {
            HostOptions.exit(withError: error)
        }
    }
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
    private struct HostedRunner {
        let task: Task<Void, Never>
        var state: RunnerServiceState
    }
    private var runners: [URL: HostedRunner] = [:]
    private let settings: HostSettingsModel
    private var statusItem: NSStatusItem?
    private var poolMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var monitoring: Task<Void, Never>?
    private var signals: [any DispatchSourceSignal] = []
    private var stopping = false
    private var stopped = false
    private var terminationReplyPending = false

    init(root: URL, logs: URL, hostRoot: URL) throws {
        self.root = root.resolvingSymlinksInPath()
        self.logs = logs
        self.settings = try HostSettingsModel(hostRoot: hostRoot, runnersRoot: root, logsDirectory: logs)
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
    }

    deinit { close(lockDescriptor) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        settings.hostState = "Running"
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { self.beginShutdown() }
            source.resume()
            signals.append(source)
        }
        monitoring = Task {
            while !Task.isCancelled {
                await settings.refreshPoolStatus()
                updatePoolMenuItem()
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
        print("Runner host started for \(root.path(percentEncoded: false)).")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "hammer.circle", accessibilityDescription: "XcodeRunnerHost")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "XcodeRunnerHost"
        let menu = NSMenu()
        let poolItem = NSMenuItem(title: "Checking execution pool…", action: nil, keyEquivalent: "")
        menu.addItem(poolItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit XcodeRunnerHost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        poolMenuItem = poolItem
    }

    private func updatePoolMenuItem() {
        if let status = settings.poolStatus {
            poolMenuItem?.title = "\(status.activeJobCount) running · Limit \(status.maximumConcurrentJobs)"
        } else {
            poolMenuItem?.title = settings.poolError == nil ? "Execution pool not configured" : "Execution pool unavailable"
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "XcodeRunnerHost Settings"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 540, height: 420)
            window.contentView = NSHostingView(rootView: HostSettingsView(model: settings))
            window.setFrameAutosaveName("XcodeRunnerHostSettings")
            window.center()
            settingsWindow = window
        }
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
        settings.hostState = "Stopping"
        monitoring?.cancel()
        Task {
            for runner in runners.values { runner.task.cancel() }
            await monitoring?.value
            for runner in runners.values { await runner.task.value }
            stopped = true
            print("Runner host stopped.")
            if terminationReplyPending {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func reconcile() async throws {
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        let requested = try Set(directories.filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                && FileManager.default.fileExists(atPath: $0.appending(path: ".xcode-runner-host").path(percentEncoded: false))
                && FileManager.default.fileExists(atPath: $0.appending(path: ".runner").path(percentEncoded: false))
        })
        for directory in runners.keys.filter({ !requested.contains($0) }) {
            let task = runners.removeValue(forKey: directory)?.task
            task?.cancel()
            await task?.value
        }
        try Task.checkCancellation()
        for directory in requested where runners[directory] == nil {
            if FileManager.default.fileExists(atPath: directory.appending(path: ".service").path(percentEncoded: false)) {
                print("Skipped \(directory.lastPathComponent): uninstall its individual service before opting in.")
                continue
            }
            runners[directory] = HostedRunner(task: Task { await serve(directory) }, state: .starting)
        }
        settings.runnerScanError = nil
        settings.runners = requested.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { directory in
            let state = runners[directory]?.state ?? .individualService
            return RunnerSettingsRow.read(directory: directory, state: state, logsDirectory: logs)
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
        for member in members.prefix(Int(count) / MemoryLayout<Int32>.stride) {
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
                environment: .inherit,
                workingDirectory: .init(directory.path(percentEncoded: false)),
                platformOptions: options,
                input: .none,
                output: .fileDescriptor(.init(rawValue: descriptor), closeAfterSpawningProcess: false),
                error: .fileDescriptor(.init(rawValue: descriptor), closeAfterSpawningProcess: false)
            ) { execution in
                self.runners[directory]?.state = .running
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
