import GhostProcessSniperCore
import SwiftUI

struct ThermalSensorStrip: View {
    let snapshot: ThermalSnapshot
    let observations: ThermalObservationWindow
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThermalSensorReading(title: "CPU temperature", value: snapshot.temperatureText(snapshot.cpuCelsius, at: now),
                reason: snapshot.unavailableReason, component: .cpu, observations: observations, now: now, tint: RadarTheme.brand)
            ThermalSensorReading(title: "GPU temperature", value: snapshot.temperatureText(snapshot.gpuCelsius, at: now),
                reason: snapshot.unavailableReason, component: .gpu, observations: observations, now: now,
                tint: RadarTheme.brandSecondary)
        }
    }
}

private struct ThermalSensorReading: View {
    let title: String
    let value: String
    let reason: String?
    let component: ThermalComponent
    let observations: ThermalObservationWindow
    let now: Date
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            RadarReading(text: value)
                .font(.system(size: value == "Unavailable" ? 18 : 30, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
            ThermalTraceView(segments: observations.segments(for: component, at: now), tint: tint, now: now)
                .frame(height: 34)
                .accessibilityHidden(true)
            Text(value == "Unavailable" ? reason ?? "No current sensor reading" : "Hottest readable hardware sensor")
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
