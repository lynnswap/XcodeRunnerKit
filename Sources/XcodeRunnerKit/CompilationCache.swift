import Foundation

/// Shares compiler outputs while keeping each job's build database isolated.
public struct CompilationCache: Sendable {
    public var directory: URL
    /// Extra locations, such as a SwiftPM checkout directory outside the workspace.
    public var prefixMappings: [PrefixMapping] = []
    public var enablesDiagnosticRemarks = false

    public init(directory: URL) {
        self.directory = directory
    }

    /// A physical source prefix and its stable compiler-visible replacement.
    public struct PrefixMapping: Sendable {
        public var source: URL
        public var replacement: String

        public init(source: URL, replacement: String) {
            self.source = source
            self.replacement = replacement
        }
    }

    func buildSettings(sourceDirectory: URL, derivedDataDirectory: URL) -> [String: String] {
        // Xcode reserves /^workspace for a package's generated workspace.
        let mappings = prefixMappings + [
            PrefixMapping(source: derivedDataDirectory, replacement: "/^xcodeRunnerDerivedData"),
            PrefixMapping(source: sourceDirectory, replacement: "/^xcodeRunnerSource"),
        ]
        let values = mappings.map { mapping in
            Self.quotedListElement(mapping.source.resolvingSymlinksInPath().path(percentEncoded: false) + "=" + mapping.replacement)
        }.joined(separator: " ")
        return [
            "COMPILATION_CACHE_ENABLE_CACHING": "YES",
            "COMPILATION_CACHE_CAS_PATH": directory.path(percentEncoded: false),
            "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": enablesDiagnosticRemarks ? "YES" : "NO",
            "SWIFT_ENABLE_PREFIX_MAPPING": "YES",
            "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING": "YES",
            "CLANG_ENABLE_PREFIX_MAPPING": "YES",
            "CLANG_ENABLE_PROJECT_PREFIX_MAPPING": "YES",
            "SWIFT_OTHER_PREFIX_MAPPINGS": values,
            "CLANG_OTHER_PREFIX_MAPPINGS": values,
        ]
    }

    private static func quotedListElement(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
