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

/// Where xcodebuild runs an operation.
public enum XcodeBuildDestination: Sendable {
    /// An xcodebuild destination specifier, such as `platform=macOS,arch=arm64`.
    case specifier(String)
    /// A Simulator that the runner leases from its pool, or creates and deletes
    /// for this operation when `reusesDevice` is false.
    case managedSimulator(SimulatorConfiguration)
}

/// The inputs and output locations for an Xcode operation.
public struct XcodeBuildRequest: Sendable {
    public var source: XcodeBuildSource
    public var scheme: String
    public var destination: XcodeBuildDestination
    /// The parent directory for a new, uniquely named job directory.
    ///
    /// The run creates this directory when it is missing, but not its ancestors.
    public var outputDirectory: URL
    /// An existing or reusable DerivedData location. Defaults to the job directory.
    public var derivedDataDirectory: URL?
    public var compilationCache: CompilationCache?
    public var environment: [String: String] = [:]
    public var buildSettings: [String: String] = [:]
    /// Additional xcodebuild arguments, including test filters and plugin options.
    public var arguments: [String] = []

    public init(
        source: XcodeBuildSource,
        scheme: String,
        destination: XcodeBuildDestination = .specifier("platform=macOS"),
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
    /// The operation's uniquely named directory inside the request's outputDirectory.
    public let jobDirectory: URL
    public let derivedDataDirectory: URL
    public let logURL: URL
    /// The requested result-bundle location. Early failures may leave no bundle.
    public let resultBundleURL: URL
    /// The leased or freshly created device identifier, retained after resource cleanup.
    public let simulatorIdentifier: String?

    public var succeeded: Bool { status == .exited(0) }

    func with(status: Status) -> Self {
        Self(
            status: status, jobDirectory: jobDirectory, derivedDataDirectory: derivedDataDirectory,
            logURL: logURL, resultBundleURL: resultBundleURL, simulatorIdentifier: simulatorIdentifier
        )
    }
}

/// An unsuccessful Xcode operation.
///
/// XcodeRunner.run reports every failure with this type, including cancellation,
/// failures before xcodebuild starts, and cleanup failures after it exits.
public struct XcodeBuildFailure: Error, LocalizedError {
    /// The job's termination state and artifact locations.
    ///
    /// Nil when the operation failed before creating its job directory. A
    /// successful status means only cleanup failed.
    public let result: XcodeBuildResult?
    /// The error that stopped the operation. A nonzero exit has no underlying error.
    public let underlyingError: (any Error)?
    /// Failures closing the log, cleaning up or deleting a Simulator, or
    /// releasing host locks after the operation, in the order they occurred.
    public let cleanupErrors: [any Error]

    init(result: XcodeBuildResult? = nil, underlyingError: (any Error)? = nil, cleanupErrors: [any Error] = []) {
        self.result = result
        self.underlyingError = underlyingError
        self.cleanupErrors = cleanupErrors
    }

    public var errorDescription: String? {
        var messages: [String] = []
        switch result?.status {
        case .exited(0)?: messages.append("The Xcode operation completed, but its cleanup failed.")
        case .exited(let code)?: messages.append("xcodebuild exited with status \(code).")
        case .terminated(let signal)?: messages.append("xcodebuild terminated with signal \(signal).")
        case .cancelled?: messages.append("The Xcode operation was cancelled.")
        case .executionFailed?, nil:
            messages.append(underlyingError is CancellationError
                ? "The Xcode operation was cancelled."
                : "The Xcode operation failed before completion.")
        }
        if let underlyingError, !(underlyingError is CancellationError) {
            messages.append(underlyingError.localizedDescription)
        }
        messages += cleanupErrors.map { "Cleanup failed: " + $0.localizedDescription }
        return messages.joined(separator: " ")
    }
}

/// An operation's result, or a failure carrying everything known about it.
typealias XcodeBuildOutcome = Result<XcodeBuildResult, XcodeBuildFailure>

extension Result where Success == XcodeBuildResult, Failure == XcodeBuildFailure {
    static func failure(wrapping error: any Error) -> Self {
        .failure(error as? XcodeBuildFailure ?? XcodeBuildFailure(underlyingError: error))
    }

    /// Keeps the operation's result and status while recording later cleanup failures.
    func addingCleanupErrors(_ errors: [any Error]) -> Self {
        guard !errors.isEmpty else { return self }
        switch self {
        case .success(let result):
            return .failure(XcodeBuildFailure(result: result, cleanupErrors: errors))
        case .failure(let failure):
            return .failure(XcodeBuildFailure(
                result: failure.result, underlyingError: failure.underlyingError,
                cleanupErrors: failure.cleanupErrors + errors
            ))
        }
    }

    /// Reports a completed operation as cancelled when its caller was cancelled during cleanup.
    func cancelledIfNeeded() -> Self {
        guard Task.isCancelled, case .success(let result) = self else { return self }
        return .failure(XcodeBuildFailure(result: result.with(status: .cancelled), underlyingError: CancellationError()))
    }
}
