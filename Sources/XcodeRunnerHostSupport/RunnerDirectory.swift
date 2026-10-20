import Foundation

/// A runner installation folder under HostInstallation.runnersRoot.
///
/// The host, the provisioner, the settings window, and storage migration read
/// the same marker files through this type. Each consumer keeps its own
/// requirements for the registration fields it reads.
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

    /// The repository ID recorded while a managed installation is incomplete, or nil.
    package func incompleteInstallationOwner() throws -> String? {
        do {
            return try String(contentsOf: url.appending(path: ".xcode-runner-installation"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// The registration fields the host reads. Fields not listed here stay untouched in the file.
    package func registration() throws -> RunnerRegistration {
        try JSONDecoder().decode(RunnerRegistration.self, from: Data(contentsOf: registrationFile))
    }

    /// The folders in a runners root, or none when the root does not exist.
    package static func all(in root: URL) throws -> [RunnerDirectory] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(RunnerDirectory.init(url:))
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

/// Registration fields saved by the official runner in `.runner`.
package struct RunnerRegistration: Decodable, Sendable {
    package let agentId: Int?
    package let agentName: String?
    package let workFolder: String?
    package let gitHubUrl: String?
    package let serverUrl: String?
}
