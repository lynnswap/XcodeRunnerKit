import Darwin
import Foundation
import XcodeRunnerHostSupport

/// Keeps the GitHub user token inside the host and its bundled read-only Git relay.
actor GitHubPackageAccess {
    private let installation: HostInstallation
    private var config: URL { installation.packageGitConfiguration }
    private let authentication: GitHubAuthentication
    private var requests: Task<Void, Never>?
    private var process: Process?
    private var input: FileHandle?
    private var acknowledgment: FileHandle?

    init(installation: HostInstallation, authentication: GitHubAuthentication) {
        self.authentication = authentication
        self.installation = installation
    }

    func update(repositories: [GitHubRepository]? = nil) throws {
        // Installation access may include repositories that the owner never intended CI jobs to read.
        let allowed: [String]
        do {
            let file = installation.packageRepositories
            allowed = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            stop()
            return
        } catch {
            stop()
            throw error
        }
        // Before the first API listing, GitHub enforces the signed-in user's access on each fetch.
        // Once listed, also recognize the installation's canonical spelling and omit public packages.
        let names: Set<String>
        if let repositories {
            let approved = Set(allowed.map { $0.lowercased() })
            let accessible = repositories.filter { $0.isPrivate == true && approved.contains($0.fullName.lowercased()) }
            let canonical = Set(accessible.map { $0.fullName.lowercased() })
            names = Set(accessible.map(\.fullName) + allowed.filter { canonical.contains($0.lowercased()) })
        } else {
            names = Set(allowed)
        }
        guard !names.isEmpty else { stop(); return }
        if process?.isRunning != true {
            stop()
            guard let relay = Bundle.module.url(forResource: "github-package-access", withExtension: "py") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let child = Process()
            child.executableURL = URL(filePath: "/usr/bin/python3")
            child.arguments = ["-I", relay.path, config.path]
            child.currentDirectoryURL = URL(filePath: "/")
            child.environment = ["PATH": "/usr/bin:/bin"]
            let commands = Pipe()
            guard fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let replies = Pipe()
            child.standardInput = commands
            child.standardOutput = replies
            let events = Pipe()
            child.standardError = events
            try child.run()
            commands.fileHandleForReading.closeFile()
            replies.fileHandleForWriting.closeFile()
            events.fileHandleForWriting.closeFile()
            process = child
            input = commands.fileHandleForWriting
            acknowledgment = replies.fileHandleForReading
            requests = Task {
                let reader = events.fileHandleForReading
                defer { reader.closeFile() }
                do {
                    for try await event in reader.bytes.lines where event == "credential" {
                        let token = (try? await authentication.accessToken()) ?? ""
                        guard process === child, !Task.isCancelled else { return }
                        try commands.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(["credential": token]) + Data([10]))
                    }
                } catch {
                    if process === child { stop() }
                }
            }
        }
        let access = ["repositories": names]
        do {
            try input?.write(contentsOf: JSONEncoder().encode(access) + Data([10]))
            guard acknowledgment?.readData(ofLength: 6) == Data("ready\n".utf8) else {
                throw HostSettingsError("GitHub package access did not start.")
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        requests?.cancel()
        requests = nil
        input?.closeFile()
        if process?.isRunning == true { process?.terminate() }
        acknowledgment?.closeFile()
        process = nil
        input = nil
        acknowledgment = nil
        // An include for a missing file is ignored by Git.
        try? FileManager.default.removeItem(at: config)
        try? FileManager.default.removeItem(at: config.deletingPathExtension().appendingPathExtension("json"))
    }
}
