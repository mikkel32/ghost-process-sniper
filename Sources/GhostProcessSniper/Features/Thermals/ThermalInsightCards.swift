import GhostProcessSniperCore
import SwiftUI

struct ThermalTemperatureHero: View {
    let diagnosis: ThermalDiagnosis
    let snapshot: ThermalSnapshot
    let history: ThermalTraceHistory?
    let now: Date

    private var tint: Color {
        if diagnosis.state == .critical { return .red }
        if diagnosis.state == .serious || diagnosis.state == .warm ||
            diagnosis.temperature.band.rawValue >= ThermalTemperatureBand.warm.rawValue { return .orange }
        return diagnosis.temperature.band == .unavailable ? .secondary : RadarTheme.brand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(diagnosis.reviewStatus.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(tint)
            Text(diagnosis.temperature.readingText)
                .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(diagnosis.headline).font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label(snapshot.temperatureText(snapshot.cpuCelsius, at: now), systemImage: "cpu")
                    .accessibilityLabel("CPU temperature: \(snapshot.temperatureText(snapshot.cpuCelsius, at: now))")
                Label(snapshot.temperatureText(snapshot.gpuCelsius, at: now), systemImage: "square.3.layers.3d")
                    .accessibilityLabel("GPU temperature: \(snapshot.temperatureText(snapshot.gpuCelsius, at: now))")
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Divider().opacity(0.5)
            Label(diagnosis.temperature.trajectory.label,
                  systemImage: diagnosis.temperature.trajectory.direction == .falling ? "arrow.down.right" : "chart.xyaxis.line")
                .font(.caption).foregroundStyle(tint)
                .help(diagnosis.temperature.trajectory.detail)
            if let history, diagnosis.temperature.band != .unavailable {
                let component: ThermalComponent = diagnosis.temperature.component == "GPU sensor" ? .gpu : .cpu
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("RECENT SENSOR TREND")
                            .font(.caption2.weight(.semibold)).tracking(0.5)
                        Spacer(minLength: 8)
                        Text(diagnosis.temperature.trajectory.detail)
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    ThermalTraceView(segments: history.segments(for: component, at: now), tint: tint, now: now)
                        .frame(height: 48)
                }
                .accessibilityElement(children: .combine)
            }
            Text(diagnosis.pressureText).font(.caption).foregroundStyle(.secondary)
            if let note = snapshot.mappingNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.17), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}
