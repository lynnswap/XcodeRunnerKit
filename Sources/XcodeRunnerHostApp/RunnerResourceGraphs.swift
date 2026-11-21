import SwiftUI

/// The runner's last two minutes on a fixed scale, with the newest sample on the right.
struct RunnerResourceGraphs: View {
    let history: RunnerMetricHistory

    var body: some View {
        Section("Activity") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { graphs }
                VStack(spacing: 12) { graphs }
            }
        }
    }

    @ViewBuilder private var graphs: some View {
        ResourceGraph(kind: .cpu, samples: history.samples)
        ResourceGraph(kind: .memory, samples: history.samples)
    }
}

private struct ResourceGraph: View {
    enum Kind { case cpu, memory }
    let kind: Kind
    let samples: [RunnerMetricSample]

    private var title: String { kind == .cpu ? "CPU Load" : "Memory Pressure" }
    private var accessibleValue: String {
        guard let latest = samples.last else { return "Waiting for samples" }
        if kind == .cpu, let cpu = latest.cpu {
            return "User \(cpu.user.formatted(.percent.precision(.fractionLength(0)))), system \(cpu.system.formatted(.percent.precision(.fractionLength(0))))"
        }
        if kind == .memory, let memory = latest.memory {
            switch memory.pressure {
            case 1: return "Normal"
            case 2: return "Warning"
            case 4: return "Critical"
            default: return "Unknown pressure level"
            }
        }
        return "Unavailable"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider().padding(.horizontal, 8)
            Canvas { context, size in
                guard let last = samples.last else { return }
                func x(_ time: Date) -> CGFloat {
                    size.width * (1 + time.timeIntervalSince(last.time) / RunnerMetricHistory.duration)
                }
                func band(from left: CGPoint, to right: CGPoint, bottomLeft: CGFloat, bottomRight: CGFloat, color: Color) {
                    var line = Path()
                    line.move(to: left)
                    line.addLine(to: right)
                    var area = line
                    area.addLine(to: CGPoint(x: right.x, y: bottomRight))
                    area.addLine(to: CGPoint(x: left.x, y: bottomLeft))
                    area.closeSubpath()
                    context.fill(area, with: .color(color.opacity(0.48)))
                    context.stroke(line, with: .color(color), lineWidth: 1)
                }
                for (index, sample) in samples.enumerated() {
                    let previous = index > 0 ? samples[index - 1] : sample
                    // After sleep or a disconnected read, leave the unobserved interval empty.
                    let left = sample.time.timeIntervalSince(previous.time) <= 15 ? previous : sample
                    let end = x(sample.time)
                    let start = min(x(left.time), end - 1)
                    switch kind {
                    case .cpu:
                        guard let cpu = sample.cpu else { continue }
                        let prior = left.cpu ?? cpu
                        let leftX = left.cpu == nil ? end - 1 : start
                        let bottom = size.height
                        let systemLeft = bottom * (1 - prior.system)
                        let systemRight = bottom * (1 - cpu.system)
                        band(from: CGPoint(x: leftX, y: systemLeft), to: CGPoint(x: end, y: systemRight),
                             bottomLeft: bottom, bottomRight: bottom, color: .red)
                        band(from: CGPoint(x: leftX, y: systemLeft - bottom * prior.user),
                             to: CGPoint(x: end, y: systemRight - bottom * cpu.user),
                             bottomLeft: systemLeft, bottomRight: systemRight, color: .cyan)
                    case .memory:
                        guard let memory = sample.memory else { continue }
                        let color: Color = switch memory.pressure {
                        case 1: .green
                        case 2: .orange
                        case 4: .red
                        default: .secondary
                        }
                        let leftX = left.memory == nil ? end - 1 : start
                        band(from: CGPoint(x: leftX, y: size.height * (1 - (left.memory ?? memory).load)),
                             to: CGPoint(x: end, y: size.height * (1 - memory.load)),
                             bottomLeft: size.height, bottomRight: size.height, color: color)
                    }
                }
            }
            .frame(height: 64)
        }
        .padding(4)
        .frame(minWidth: 136, maxWidth: .infinity)
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibleValue)
        .help(kind == .cpu ? "Last two minutes. Cyan is user CPU and red is system CPU." : "Last two minutes. Green is normal, orange is warning, and red is critical.")
    }
}
