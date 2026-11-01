import Foundation

/// A runner installation folder under HostInstallation.runnersRoot.
///
/// The host, the provisioner, the settings window, and storage migration read
/// the same marker files through this type. Each consumer decodes only the
/// registration fields it uses, so an unexpected value in another field does
/// not hide an otherwise usable runner.
package struct RunnerDirectory: Sendable, Hashable {
    package let url: URL

    package init(url: URL) {
        self.url = url
    }

    package var name: String { url.lastPathComponent }
    /// The official runner's registration settings.
    package var registrationFile: URL { url.appending(path: ".runner") }

    /// Whether the runner opted in to the common host, which then starts its service.
    package func isHosted() throws -> Bool { try itemExists(".xcode-runner-host") }
    /// Whether the runner still has its own launchd service.
    package func hasIndividualService() throws -> Bool { try itemExists(".service") }
    /// Whether the official runner saved its registration settings.
    package func hasRegistration() throws -> Bool { try itemExists(".runner") }
    /// Whether the registration was removed from GitHub, so the host stops the service and deletes the folder.
    package func isRemoved() throws -> Bool { try itemExists(".xcode-runner-removed") }

    /// Asks the host to stop the service and delete the folder.
    package func markRemoved() throws {
        try Data().write(to: url.appending(path: ".xcode-runner-removed"))
    }

    /// The ID of the repository that this Mac started removing the registration from, or nil.
    package func unregisteringRepository() throws -> String? { try text(of: ".xcode-runner-unregistering") }

    /// Records that this Mac removes the registration from a repository, so that the folder can still be removed
    /// after GitHub stops listing the runner.
    package func markUnregistering(from repositoryID: Int) throws {
        try Data(String(repositoryID).utf8).write(to: url.appending(path: ".xcode-runner-unregistering"))
    }

    /// The repository ID recorded while a managed installation is incomplete, or nil.
    package func incompleteInstallationOwner() throws -> String? { try text(of: ".xcode-runner-installation") }

    /// Decodes the registration fields that `Fields` declares, leaving the others unchecked.
    package func registration<Fields: Decodable>(as fields: Fields.Type) throws -> Fields {
        try JSONDecoder().decode(Fields.self, from: Data(contentsOf: registrationFile))
    }

    /// The folders in a runners root, and the entries whose type could not be read.
    ///
    /// The root itself may be missing. Each caller decides whether an unreadable
    /// entry stops its work or is reported for that runner alone.
    package static func scan(_ root: URL) throws -> RunnerDirectoryScan {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return RunnerDirectoryScan()
        }
        var scan = RunnerDirectoryScan()
        for entry in entries {
            do {
                if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    scan.directories.append(RunnerDirectory(url: entry))
                } else {
                    scan.otherEntries.append(entry)
                }
            } catch {
                scan.unreadable.append(UnreadableRunnerEntry(directory: RunnerDirectory(url: entry), error: error))
            }
        }
        return scan
    }

    private func text(of name: String) throws -> String? {
        do {
            return try String(contentsOf: url.appending(path: name), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func itemExists(_ name: String) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.appending(path: name).path(percentEncoded: false))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}

package struct RunnerDirectoryScan: Sendable {
    package var directories: [RunnerDirectory] = []
    package var unreadable: [UnreadableRunnerEntry] = []
    /// Entries that are not folders, such as files.
    package var otherEntries: [URL] = []
}

package struct UnreadableRunnerEntry: Sendable {
    package let directory: RunnerDirectory
    package let error: any Error
}
