import Foundation

/// The Xcode project or Swift package containing a scheme.
public enum XcodeBuildSource: Sendable, Equatable {
    case workspace(URL)
    case project(URL)
    case package(URL)

    var workingDirectory: URL {
        switch self {
        case .workspace(let url), .project(let url): url.deletingLastPathComponent()
        case .package(let url): url
        }
    }

    func canonicalized() throws -> Self {
        switch self {
        case .workspace(let url): .workspace(try url.compilerCanonicalURL())
        case .project(let url): .project(try url.compilerCanonicalURL())
        case .package(let url): .package(try url.compilerCanonicalURL())
        }
    }

    var arguments: [String] {
        switch self {
        case .workspace(let url): ["-workspace", url.path(percentEncoded: false)]
        case .project(let url): ["-project", url.path(percentEncoded: false)]
        case .package: []
        }
    }
}

/// An operation supported by xcodebuild.
public enum XcodeBuildAction: String, Sendable, CaseIterable {
    case build
    case buildForTesting = "build-for-testing"
    case test
    case testWithoutBuilding = "test-without-building"
}

/// The inputs and output locations for an Xcode operation.
public struct XcodeBuildRequest: Sendable {
    public var source: XcodeBuildSource
    public var scheme: String
    public var destination: String
    /// The parent directory for a new, uniquely named job directory.
    public var outputDirectory: URL
    /// An existing or reusable DerivedData location. Defaults to the job directory.
    public var derivedDataDirectory: URL?
    public var compilationCache: CompilationCache?
    /// Creates a job-owned Simulator and overrides destination with its UDID.
    public var simulator: SimulatorConfiguration?
    public var environment: [String: String] = [:]
    public var buildSettings: [String: String] = [:]
    /// Additional xcodebuild arguments, including test filters and plugin options.
    public var arguments: [String] = []

    public init(
        source: XcodeBuildSource,
        scheme: String,
        destination: String = "platform=macOS",
        outputDirectory: URL
    ) {
        self.source = source
        self.scheme = scheme
        self.destination = destination
        self.outputDirectory = outputDirectory
    }
}

/// The termination state and artifact locations of an Xcode operation.
public struct XcodeBuildResult: Sendable {
    public enum Status: Sendable, Equatable {
        case exited(Int32)
        case terminated(Int32)
        case cancelled
        case executionFailed
    }

    public let status: Status
    public let outputDirectory: URL
    public let derivedDataDirectory: URL
    public let logURL: URL
    /// The requested result-bundle location. Early failures may leave no bundle.
    public let resultBundleURL: URL
    /// The job-owned device identifier, retained after device cleanup.
    public let simulatorIdentifier: String?

    public var succeeded: Bool { status == .exited(0) }
}

/// An unsuccessful operation, including any execution and log-cleanup failures.
public struct XcodeBuildFailure: Error, LocalizedError {
    public let result: XcodeBuildResult
    public let underlyingError: (any Error)?
    public let cleanupError: (any Error)?

    public var errorDescription: String? {
        let message: String
        switch result.status {
        case .exited(0): message = "Closing the Xcode log failed."
        case .exited(let code): message = "xcodebuild exited with status \(code)."
        case .terminated(let signal): message = "xcodebuild terminated with signal \(signal)."
        case .cancelled: message = "The Xcode operation was cancelled."
        case .executionFailed: message = "The Xcode operation failed before completion."
        }
        return [message, underlyingError?.localizedDescription, cleanupError?.localizedDescription]
            .compactMap { $0 }.joined(separator: " ")
    }
}
