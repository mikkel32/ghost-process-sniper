import GhostProcessSniperCore
import SwiftUI

struct ThermalStatusCard: View {
    let diagnosis: ThermalDiagnosis

    private var tint: Color {
        if diagnosis.state == .critical { return .red }
        if diagnosis.state == .serious || diagnosis.state == .warm ||
            diagnosis.temperature.band.rawValue >= ThermalTemperatureBand.warm.rawValue { return .orange }
        if diagnosis.temperature.band == .unavailable { return .secondary }
        return switch diagnosis.state {
        case .checking: .secondary
        case .normal: RadarTheme.brand
        case .warm, .serious: .orange
        case .critical: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: diagnosis.temperature.trajectory.direction == .falling ? "arrow.down.right" : "thermometer.medium")
                    .font(.title2).foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(diagnosis.reviewStatus.uppercased())
                        .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(tint)
                    Text(diagnosis.headline).font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(diagnosis.explanation).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    pressureLabel
                    trendLabel
                }
                VStack(alignment: .leading, spacing: 8) {
                    pressureLabel
                    trendLabel
                }
            }
            if let persistence = diagnosis.temperature.persistenceText {
                Text(persistence).font(.caption.monospacedDigit()).foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.13), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    private var pressureLabel: some View {
        Label(diagnosis.pressureText, systemImage: "waveform.path")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var trendLabel: some View {
        Label(diagnosis.temperature.trajectory.label, systemImage: "chart.xyaxis.line")
            .font(.caption).foregroundStyle(.secondary)
            .help("\(diagnosis.temperature.component): \(diagnosis.temperature.trajectory.detail)")
    }
}

struct ThermalSensorStrip: View {
    let snapshot: ThermalSnapshot
    let history: ThermalTraceHistory?
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThermalSensorReading(title: "CPU temperature", value: snapshot.temperatureText(snapshot.cpuCelsius, at: now),
                component: .cpu, history: history, now: now, tint: RadarTheme.brand)
            ThermalSensorReading(title: "GPU temperature", value: snapshot.temperatureText(snapshot.gpuCelsius, at: now),
                component: .gpu, history: history, now: now, tint: RadarTheme.brandSecondary)
        }
    }
}

private struct ThermalSensorReading: View {
    let title: String
    let value: String
    let component: ThermalComponent
    let history: ThermalTraceHistory?
    let now: Date
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            RadarReading(text: value)
                .font(.system(size: value == "Unavailable" ? 18 : 30, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let history {
                ThermalTraceView(segments: history.segments(for: component, at: now), tint: tint, now: now)
                    .frame(height: 34)
                    .accessibilityHidden(true)
            }
            Text(value == "Unavailable" ? "No current sensor reading" : "Hottest readable hardware sensor")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}
