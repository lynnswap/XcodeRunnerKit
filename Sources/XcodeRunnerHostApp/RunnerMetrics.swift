import Darwin
import Foundation

/// One sample from the runner Mac. CPU fractions include all its processors.
struct RunnerMetricSample: Codable, Equatable, Sendable {
    struct CPU: Codable, Equatable, Sendable {
        let user: Double
        let system: Double
    }

    struct Memory: Codable, Equatable, Sendable {
        let load: Double
        let pressure: Int32
    }

    let time: Date
    let cpu: CPU?
    let memory: Memory?
}

struct RunnerMetricHistory {
    static let duration: TimeInterval = 120
    private(set) var samples: [RunnerMetricSample] = []

    mutating func append(_ sample: RunnerMetricSample) {
        if let last = samples.last, sample.time <= last.time { return }
        samples.removeAll { sample.time.timeIntervalSince($0.time) > Self.duration }
        samples.append(sample)
    }
}

struct RunnerMetricSampler {
    private var previousCPU: host_cpu_load_info_data_t?

    mutating func sample() -> RunnerMetricSample {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var ticks = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: ticks) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &ticks) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        var cpu: RunnerMetricSample.CPU?
        if status == KERN_SUCCESS {
            if let previousCPU {
                let now = ticks.cpu_ticks
                let before = previousCPU.cpu_ticks
                let user = Double(now.0 &- before.0) + Double(now.3 &- before.3)
                let system = Double(now.1 &- before.1)
                let total = user + system + Double(now.2 &- before.2)
                if total > 0 { cpu = .init(user: user / total, system: system / total) }
            }
            previousCPU = ticks
        } else {
            previousCPU = nil
        }

        // Activity Monitor plots the inverse kernel memory-status level. The VM pressure level selects the color.
        var memory: RunnerMetricSample.Memory?
        if let free = Self.kernelValue("kern.memorystatus_level"), (0...100).contains(free),
           let pressure = Self.kernelValue("kern.memorystatus_vm_pressure_level") {
            memory = .init(load: Double(100 - free) / 100, pressure: pressure)
        }
        return RunnerMetricSample(time: .now, cpu: cpu, memory: memory)
    }

    private static func kernelValue(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout.size(ofValue: value) else { return nil }
        return value
    }
}
