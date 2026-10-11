import CProbe
import Observation

@Observable
public final class Counter {
    public var value = 0
    public init() {}
    public func increment() { value += 1 }
}

public func doubled(_ value: Int32) -> Int32 { probe_double(value) }
