import AppKit
import Foundation

/// An Xcode on this Mac that a host's jobs can use.
package struct InstalledXcode: Codable, Equatable, Identifiable, Sendable {
    /// The Xcode's `Contents/Developer` directory, which selects it for xcodebuild.
    package let developerDirectory: URL
    package let version: String
    /// The build that distinguishes betas of one version, such as `27B48`.
    package let build: String?

    package var id: URL { developerDirectory }
    package var name: String { build.map { "Xcode \(version) (\($0))" } ?? "Xcode \(version)" }

    package init(developerDirectory: URL, version: String, build: String?) {
        self.developerDirectory = developerDirectory
        self.version = version
        self.build = build
    }

    /// The Xcode apps on this Mac, newest first: the ones in the Applications folders, and the ones that Launch
    /// Services knows elsewhere.
    package static func installed() -> [InstalledXcode] {
        struct Version: Decodable {
            let version: String
            let build: String?

            enum CodingKeys: String, CodingKey {
                case version = "CFBundleShortVersionString", build = "ProductBuildVersion"
            }
        }
        let identifier = "com.apple.dt.Xcode"
        // Launch Services leaves out an Xcode that this macOS no longer opens as an app, although xcodebuild still
        // builds with it.
        let folders = [URL(filePath: "/Applications"), URL.homeDirectory.appending(path: "Applications")]
        let inFolders = folders.flatMap { folder in
            // A user may have no Applications folder.
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        .filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == identifier }
        var found: [URL: InstalledXcode] = [:]
        for app in inFolders + NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier) {
            // An app that cannot be read, such as one on a volume being ejected, is not offered.
            guard let data = try? Data(contentsOf: app.appending(path: "Contents/version.plist")),
                  let version = try? PropertyListDecoder().decode(Version.self, from: data) else { continue }
            // The same spelling as a saved directory, which has no trailing slash.
            let developerDirectory = URL(
                filePath: app.standardizedFileURL.appending(path: "Contents/Developer").path(percentEncoded: false),
                directoryHint: .notDirectory
            )
            found[developerDirectory] = InstalledXcode(
                developerDirectory: developerDirectory, version: version.version, build: version.build
            )
        }
        return found.values.sorted {
            let order = $0.version.compare($1.version, options: .numeric)
            return order == .orderedSame ? $0.developerDirectory.path < $1.developerDirectory.path : order == .orderedDescending
        }
    }
}
