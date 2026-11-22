import ArgumentParser
import Darwin
import Foundation

package struct InstallSkill: ParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "init", abstract: "Install the bundled xcode-runner agent skill on this Mac."
    )

    enum Client: String, ExpressibleByArgument {
        case auto, agents, claude
    }

    @Option(help: "Install for agents (~/.agents/skills), claude (~/.claude/skills), or auto-detect interactively.")
    var client: Client = .auto
    @Option(help: "Use this skills directory instead of a client default.")
    var dest: String?
    @Flag(name: .customLong("print"), help: "Write the bundled SKILL.md to standard output.")
    var printSkill = false
    @Flag(help: "Replace an existing SKILL.md.")
    var force = false
    @Flag(help: "Remove the installed xcode-runner skill.")
    var uninstall = false

    package init() {}

    package func run() throws {
        let content = Data(PackageResources.SKILL_md)
        if printSkill {
            guard !uninstall && !force && dest == nil && client == .auto else {
                throw ValidationError("Use --print on its own.")
            }
            FileHandle.standardOutput.write(content)
            return
        }

        let files = FileManager.default
        let roots: [URL]
        if let dest {
            roots = [URL(filePath: (dest as NSString).expandingTildeInPath)]
        } else {
            let home = ProcessInfo.processInfo.environment["HOME"].map { URL(filePath: $0) }
                ?? files.homeDirectoryForCurrentUser
            let clients: [Client]
            if client == .auto {
                guard isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 else {
                    throw ValidationError("Choose --client or --dest when running noninteractively.")
                }
                clients = [.agents, .claude].filter { files.fileExists(atPath: home.appending(path: ".\($0.rawValue)").path) }
                guard !clients.isEmpty else { throw ValidationError("Choose --client or --dest to select a skills directory.") }
            } else {
                clients = [client]
            }
            roots = clients.map { home.appending(path: ".\($0.rawValue)/skills") }
        }

        for root in roots {
            let directory = root.appending(path: "xcode-runner", directoryHint: .isDirectory)
            var entry = stat()
            if lstat(directory.path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFLNK {
                throw ValidationError("The skill directory is a symbolic link: \(directory.path)")
            }
            let file = directory.appending(path: "SKILL.md")
            if uninstall {
                guard unlink(file.path) == 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                // rmdir only removes an empty directory. Keep any files added by the user.
                if rmdir(directory.path) != 0 && errno != ENOTEMPTY && errno != ENOENT {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                print("Removed \(file.path)")
            } else {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                do {
                    try content.write(to: file, options: force ? .atomic : .withoutOverwriting)
                } catch CocoaError.fileWriteFileExists {
                    throw ValidationError("A skill exists at \(file.path). Use --force to replace it.")
                }
                print("Installed \(file.path)")
            }
        }
    }
}
