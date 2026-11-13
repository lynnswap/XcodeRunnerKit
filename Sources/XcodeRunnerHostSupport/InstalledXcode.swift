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

    /// The Xcode apps that Launch Services knows on this Mac, newest first.
    package static func installed() -> [InstalledXcode] {
        struct Version: Decodable {
            let version: String
            let build: String?

            enum CodingKeys: String, CodingKey {
                case version = "CFBundleShortVersionString", build = "ProductBuildVersion"
            }
        }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.dt.Xcode").compactMap { app in
            // An app that cannot be read, such as one on a volume being ejected, is not offered.
            guard let data = try? Data(contentsOf: app.appending(path: "Contents/version.plist")),
                  let version = try? PropertyListDecoder().decode(Version.self, from: data) else { return nil }
            return InstalledXcode(
                developerDirectory: app.appending(path: "Contents/Developer").standardizedFileURL,
                version: version.version, build: version.build
            )
        }
        .sorted {
            let order = $0.version.compare($1.version, options: .numeric)
            return order == .orderedSame ? $0.developerDirectory.path < $1.developerDirectory.path : order == .orderedDescending
        }
    }
}
