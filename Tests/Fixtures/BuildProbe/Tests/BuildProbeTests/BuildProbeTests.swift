import BuildProbe
import Foundation
import Testing

@Test func countsAndCallsClangTarget() {
    let counter = Counter()
    counter.increment()
    #expect(counter.value == 1)
    #expect(doubled(4) == 8)
}

@Test func controlledPayload() async throws {
    let mode = ProcessInfo.processInfo.environment["PROBE_MODE"] ?? "success"
    try FileHandle.standardOutput.write(contentsOf: Data("BuildProbe payload ready\n".utf8))
    if mode == "failure" { #expect(Bool(false)) }
    if mode == "wait" { try await Task.sleep(for: .seconds(120)) }
}
