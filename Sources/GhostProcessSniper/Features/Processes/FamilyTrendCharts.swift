import Charts
import GhostProcessSniperCore
import SwiftUI

struct FamilyTrendPanel: View, Equatable {
    let samples: [TrendSample]
    let velocity: Double
    let pattern: MemoryPatternAnalysis
    let fitQuality: Double
    let hasFit: Bool
    let cpuPercent: Double
    let level: GhostLevel

    private var tint: Color {
        velocity > 0 ? RadarStyle.color(for: max(level, .watch)) : .green
    }

    /// Where the current leak rate lands in 3 minutes, drawn only when the
    /// shape says memory is truly accumulating.
    private var projection: (date: Date, megabytes: Double)? {
        guard velocity > 1, pattern.pattern.indicatesAccumulation, let last = samples.last else { return nil }
        return (last.date.addingTimeInterval(180), Double(last.memoryBytes) / 1_048_576 + velocity * 3)
    }

    private var fitText: String {
        guard hasFit else { return "warming up" }
        let percent = Int((fitQuality * 100).rounded())
        if fitQuality >= 0.8 { return "\(percent)% steady" }
        if fitQuality >= 0.4 { return "\(percent)% mixed" }
        return "\(percent)% noisy"
    }

    var body: some View {
        RadarSection(
            title: "Memory Trend",
            subtitle: pattern.pattern.label,
            systemImage: "chart.xyaxis.line",
            tip: RadarTip(
                title: "Memory Trend",
                message: "Live footprint over the sampling window — hover the chart for exact values. The dashed line projects the current leak rate 3 minutes ahead (only drawn when the shape says memory is truly accumulating). Trend fit is the regression R²: steady means the slope is trustworthy, noisy means don't panic over it yet."
            ),
            accent: .blue
        ) {
            HStack(spacing: 16) {
                VStack(spacing: 8) {
                    MemoryTrendChart(
                        samples: samples,
                        projection: projection,
                        tint: tint,
                        summary: "\(pattern.pattern.label), \(RadarFormat.leak(velocity))"
                    )
                    .frame(height: 132)
                    CPUTrendChart(samples: samples)
                        .frame(height: 44)
                }
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    metric("Leak velocity", RadarFormat.leak(velocity))
                    metric("Current CPU", RadarFormat.percent(cpuPercent))
                    metric("Trend fit", fitText)
                    metric("Pattern", pattern.pattern.label)
                }
                .frame(width: 170, alignment: .leading)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: value)
        }
        .accessibilityElement(children: .combine)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.samples == rhs.samples && lhs.velocity == rhs.velocity && lhs.pattern == rhs.pattern &&
            lhs.fitQuality == rhs.fitQuality && lhs.hasFit == rhs.hasFit &&
            lhs.cpuPercent == rhs.cpuPercent && lhs.level == rhs.level
    }
}

/// Owns its hover state, so moving the pointer re-renders only this chart,
/// and only when the nearest sample changes.
struct MemoryTrendChart: View {
    let samples: [TrendSample]
    let projection: (date: Date, megabytes: Double)?
    let tint: Color
    /// Pattern and leak rate, read by VoiceOver in place of the picture.
    let summary: String

    @State private var hoveredDate: Date?

    var body: some View {
        if samples.count >= 2 {
            chart
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Collecting samples\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var chart: some View {
        let fill = LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        let hovered = hoveredDate.flatMap { date in samples.first { $0.date == date } }
        return Chart {
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    y: .value("Memory in MB", Double(sample.memoryBytes) / 1_048_576)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(fill)
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Memory in MB", Double(sample.memoryBytes) / 1_048_576),
                    series: .value("Series", "measured")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .foregroundStyle(tint.gradient)
            }

            if let projection, let last = samples.last {
                LineMark(
                    x: .value("Time", last.date),
                    y: .value("Memory in MB", Double(last.memoryBytes) / 1_048_576),
                    series: .value("Series", "projected")
                )
                .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                .foregroundStyle(tint.opacity(0.55))
                LineMark(
                    x: .value("Time", projection.date),
                    y: .value("Memory in MB", projection.megabytes),
                    series: .value("Series", "projected")
                )
                .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                .foregroundStyle(tint.opacity(0.55))
                .annotation(position: .topTrailing, alignment: .trailing) {
                    Text("projected")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let hovered {
                RuleMark(x: .value("Time", hovered.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.secondary.opacity(0.5))
                PointMark(
                    x: .value("Time", hovered.date),
                    y: .value("Memory in MB", Double(hovered.memoryBytes) / 1_048_576)
                )
                .symbolSize(46)
                .foregroundStyle(tint)
                .annotation(position: .top) {
                    VStack(spacing: 1) {
                        Text(RadarFormat.bytes(hovered.memoryBytes))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                        Text(hovered.date.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second(), anchor: .top)
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let megabytes = value.as(Double.self) {
                        Text(RadarFormat.bytes(UInt64(max(0, megabytes) * 1_048_576)))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame,
                                  let date: Date = proxy.value(atX: location.x - geo[plotFrame].origin.x) else {
                                setHovered(nil)
                                return
                            }
                            setHovered(nearestSample(to: date)?.date)
                        case .ended:
                            setHovered(nil)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory trend")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let projection else { return summary }
        return "\(summary), projected \(RadarFormat.bytes(UInt64(max(0, projection.megabytes) * 1_048_576))) in 3 minutes"
    }

    private func setHovered(_ date: Date?) {
        if hoveredDate != date { hoveredDate = date }
    }

    /// Samples arrive in time order, so a binary search finds the nearest.
    private func nearestSample(to date: Date) -> TrendSample? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].date < date { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return samples[low] }
        let before = samples[low - 1]
        let after = samples[low]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }
}

struct CPUTrendChart: View {
    let samples: [TrendSample]

    var body: some View {
        if samples.count >= 2 {
            Chart(samples) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("CPU percent", sample.cpuPercent)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .foregroundStyle(Color.orange.gradient)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent))%")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Text("CPU")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CPU trend")
            .accessibilityValue(samples.last.map { RadarFormat.percent($0.cpuPercent) } ?? "")
        }
    }
}

struct FamilyOverviewChips: View, Equatable {
    let memoryBytes: UInt64
    let cpuPercent: Double
    let velocity: Double
    let baselineText: String
    let level: GhostLevel

    var body: some View {
XX, RadarFormat.bytes(memoryBytes), "memorychip", level >= .hot ? level : .quiet)
            chip("CPU", RadarFormat.percent(cpuPercent), "cpu", cpuPercent >= 80 ? .hot : .quiet)
            chip("Leak", RadarFormat.leak(velocity), "chart.line.uptrend.xyaxis", velocity > 0 ? .watch : .quiet)
            chip("vs Normal", baselineText, "ruler", .quiet)
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.memoryBytes == rhs.memoryBytes && lhs.cpuPercent == rhs.cpuPercent && lhs.velocity == rhs.velocity &&
            lhs.baselineText == rhs.baselineText && lhs.level == rhs.level
    }

    private func chip(_ title: String, _ value: String, _ systemImage: String, _ level: GhostLevel) -> some View {
        RadarChip(title: title, value: value, systemImage: systemImage, level: level)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
