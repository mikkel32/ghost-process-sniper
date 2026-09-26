import GhostProcessSniperCore
import SwiftUI

struct ThermalTraceView: View {
    let segments: [ThermalTraceSegment]
    let tint: Color
    let now: Date

    var body: some View {
        Canvas { context, size in
            let points = segments.flatMap(\.points)
            guard let first = points.first, let last = points.last, points.count > 1 else { return }
            let values = points.map(\.celsius)
            let low = floor(((values.min() ?? 0) - 2) / 5) * 5
            let high = max(low + 10, ceil(((values.max() ?? 0) + 2) / 5) * 5)
            let end = max(last.date, now)
            let span = max(30, end.timeIntervalSince(first.date))
            let start = end.addingTimeInterval(-span)
            func location(_ point: ThermalTracePoint) -> CGPoint {
                CGPoint(x: 3 + point.date.timeIntervalSince(start) / span * max(0, size.width - 6),
                        y: 4 + (1 - (point.celsius - low) / (high - low)) * max(0, size.height - 8))
            }
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: size.height / 2))
            guide.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(guide, with: .color(tint.opacity(0.15)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 4]))
            for segment in segments {
                guard let beginning = segment.points.first else { continue }
                var line = Path()
                line.move(to: location(beginning))
                for point in segment.points.dropFirst() { line.addLine(to: location(point)) }
                context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            let endpoint = location(last)
            context.fill(Path(ellipseIn: CGRect(x: endpoint.x - 2.5, y: endpoint.y - 2.5, width: 5, height: 5)), with: .color(tint))
        }
        .overlay {
            if segments.flatMap(\.points).count < 2 {
                Text("Collecting sensor trace")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel(Self.summary(segments))
    }

    static func summary(_ segments: [ThermalTraceSegment]) -> String {
        let values = segments.flatMap(\.points).map(\.celsius)
        guard values.count > 1, let low = values.min(), let high = values.max() else { return "Collecting sensor history." }
        return String(format: "Recent sensor range %.1f to %.1f degrees Celsius. Gaps represent missing readings.", low, high)
    }
}
