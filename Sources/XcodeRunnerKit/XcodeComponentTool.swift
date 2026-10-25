import Darwin
import Foundation
import Subprocess

/// Serializes Apple's component installers across cooperating builds on this Mac.
struct XcodeComponentTool: Sendable {
    var executableURL = URL(filePath: "/usr/bin/xcodebuild")
    var environment: [String: String] = [:]
    var lockURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "XcodeRunnerKit/ComponentDownloads.lock")

    func download(arguments: [String], onOutput: (@Sendable (Data) throws -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(lockURL.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let lock = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let outcome: Result<Void, any Error>
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            var options = PlatformOptions()
            options.createSession = true
            options.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)]
            // A downloader surviving its parent must continue holding the shared lock.
            options.preSpawnProcessConfigurator = { _, actions in
                let error = posix_spawn_file_actions_addinherit_np(&actions, descriptor)
                guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
            }
            let result = try await Subprocess.run(
                .path(.init(executableURL.path(percentEncoded: false))), arguments: .init(arguments),
                environment: .inherit.updating(Dictionary(uniqueKeysWithValues: environment.map {
                    (Environment.Key(stringLiteral: $0.key), Optional($0.value))
                })),
                platformOptions: options, input: .none, output: .sequence, error: .combinedWithOutput
            ) { execution in
                var tail = Data()
                for try await buffer in execution.standardOutput {
                    let data = buffer.withUnsafeBytes { Data($0) }
                    try onOutput?(data)
                    tail.append(data)
                    if tail.count > 65_536 { tail.removeFirst(tail.count - 65_536) }
                }
                return tail
            }
            try Task.checkCancellation()
            guard result.terminationStatus.isSuccess else {
                throw NSError(domain: "XcodeRunnerKit.components", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "xcodebuild \(arguments.joined(separator: " ")) failed: \(result.terminationStatus). \(String(decoding: result.closureResult, as: UTF8.self))",
                ])
            }
            outcome = .success(())
        } catch { outcome = .failure(error) }
        do { try lock.close() }
        catch {
            throw HostExecutionCleanupFailure(operationError: outcome.failure, cleanupError: error)
        }
        try outcome.get()
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
