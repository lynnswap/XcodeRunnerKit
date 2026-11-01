import Foundation

/// The GitHub App that hosts sign in through and that users install on their repositories.
struct GitHubApp: Equatable, Sendable {
    let clientID: String
    let slug: String

    /// The shared app owned by the pd-kit organization. A build that signs in through another app
    /// changes these values; that app needs Device Flow and the permissions in NativeHost.md.
    static let xcodeHomeRunner = GitHubApp(clientID: "Iv23li8omT6XnFXwiMP4", slug: "xcodehomerunner")

    /// The page where the user installs the app and chooses the repositories it can access.
    var installationURL: URL {
        URL(string: "https://github.com/apps")!.appending(components: slug, "installations", "new")
    }
}
