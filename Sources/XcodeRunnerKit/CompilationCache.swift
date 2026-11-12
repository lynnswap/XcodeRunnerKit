import Foundation

extension URL {
    func compilerCanonicalURL() throws -> URL {
        // resolvingSymlinksInPath removes /private, unlike compiler filesystem paths.
        guard let path = try resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: self])
        }
        return URL(filePath: path)
    }

    /// The spellings under which compilers and Xcode name this location.
    ///
    /// Symbolic links are resolved through the deepest existing ancestor,
    /// because a build can create the rest.
    var compilerVisiblePaths: [String] {
        var existing = self
        var missing: [String] = []
        var physical = existing.physicalPath
        while physical == nil, existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
            physical = existing.physicalPath
        }
        guard let physical else { return [path(percentEncoded: false)] }
        // Xcode passes paths under /private/tmp and /private/var without /private.
        let standardized = (physical as NSString).standardizingPath
        return (standardized == physical ? [physical] : [physical, standardized]).map { spelling in
            missing.reduce(URL(filePath: spelling)) { $0.appending(path: $1) }.path(percentEncoded: false)
        }
    }

    /// The path with every symbolic link resolved, or nil when the location does not exist.
    private var physicalPath: String? {
        // canonicalPathKey leaves a symbolic link in the last component unresolved.
        guard let resolved = realpath(path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Shares compiler outputs while keeping each job's build database isolated.
public struct CompilationCache: Sendable {
    /// The shared CAS directory. A run creates it when it is missing.
    public var directory: URL
    /// Whether checkouts at different paths share entries.
    ///
    /// When true, the compiler sees the source directory under a fixed
    /// placeholder. `#filePath`, `__FILE__`, test failure locations, debug
    /// information, and coverage data then name that placeholder instead of
    /// files on disk, so leave this false for tests and tools that open source
    /// files through those paths. When false, jobs share entries for a checkout
    /// at the same path.
    public var mapsSourceDirectory = false
    /// Extra locations, such as a SwiftPM checkout directory outside the workspace.
    public var prefixMappings: [PrefixMapping] = []
    public var enablesDiagnosticRemarks = false
    let parentDirectory: URL?

    /// Uses the supplied directory without creating missing ancestors.
    public init(directory: URL) {
        self.directory = directory
        self.parentDirectory = nil
    }

    package init(directory: URL, namespace: String) {
        self.directory = directory.appending(path: namespace, directoryHint: .isDirectory)
        self.parentDirectory = directory
    }

    /// A source prefix and its stable compiler-visible replacement.
    ///
    /// The source may name its location through symbolic links.
    public struct PrefixMapping: Sendable {
        public var source: URL
        public var replacement: String

        public init(source: URL, replacement: String) {
            self.source = source
            self.replacement = replacement
        }
    }

    func buildSettings(sourceDirectory: URL, derivedDataDirectory: URL) -> [String: String] {
        var mappings = prefixMappings + [
            PrefixMapping(source: derivedDataDirectory, replacement: "/^xcodeRunnerDerivedData"),
        ]
        var settings = [
            "COMPILATION_CACHE_ENABLE_CACHING": "YES",
            "COMPILATION_CACHE_CAS_PATH": directory.path(percentEncoded: false),
            "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": enablesDiagnosticRemarks ? "YES" : "NO",
            "SWIFT_ENABLE_PREFIX_MAPPING": "YES",
            "CLANG_ENABLE_PREFIX_MAPPING": "YES",
        ]
        if mapsSourceDirectory {
            // Xcode reserves /^workspace for a package's generated workspace.
            mappings.append(PrefixMapping(source: sourceDirectory, replacement: "/^xcodeRunnerSource"))
            // Project mapping replaces each project's own directory with /^src.
            settings["SWIFT_ENABLE_PROJECT_PREFIX_MAPPING"] = "YES"
            settings["CLANG_ENABLE_PROJECT_PREFIX_MAPPING"] = "YES"
        }
        let values = "$(inherited) " + mappings.flatMap { mapping in
            mapping.source.compilerVisiblePaths.map { Self.quotedListElement($0 + "=" + mapping.replacement) }
        }.joined(separator: " ")
        settings["SWIFT_OTHER_PREFIX_MAPPINGS"] = values
        settings["CLANG_OTHER_PREFIX_MAPPINGS"] = values
        return settings
    }

    private static func quotedListElement(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
