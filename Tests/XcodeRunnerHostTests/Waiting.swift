/// Polls until the condition holds.
///
/// There is no deadline because how long fake tools and processes take to
/// start depends on the machine. The suite's time limit fails a test whose
/// condition never holds.
nonisolated(nonsending) func waitUntil(_ condition: () async throws -> Bool) async throws {
    while try await !condition() {
        try await Task.sleep(for: .milliseconds(20))
    }
}
