import GhostProcessSniperCore
import SwiftUI

struct ThermalDashboardView: View {
    let snapshot: ThermalSnapshot
    var observations: ThermalObservationWindow? = nil

    var body: some View {
        // Expires sensor values even when sampling is paused or fails to publish.
        TimelineView(.explicit(ThermalExpirySchedule.dates([snapshot.expiresAt]))) { _ in
            content(at: Date())
        }
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Label("Thermal telemetry", systemImage: "thermometer.medium")
                    .font(.headline)
                Spacer(minLength: 8)
                Label(snapshot.sensorCount > 0 ? "\(snapshot.sensorCount) sensors" : "Sensor status", systemImage: "sensor")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    temperature("CPU", value: snapshot.cpuCelsius, symbol: "cpu", component: .cpu, tint: RadarTheme.brand, at: now)
                        .frame(minWidth: 155)
                    temperature("GPU", value: snapshot.gpuCelsius, symbol: "square.stack.3d.up", component: .gpu, tint: RadarTheme.brandSecondary, at: now)
                        .frame(minWidth: 155)
                    systemReport.frame(minWidth: 155)
                }
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        temperature("CPU", value: snapshot.cpuCelsius, symbol: "cpu", component: .cpu, tint: RadarTheme.brand, at: now)
                        temperature("GPU", value: snapshot.gpuCelsius, symbol: "square.stack.3d.up", component: .gpu, tint: RadarTheme.brandSecondary, at: now)
                    }
                    systemReport
                }
            }
            Text(snapshot.unavailableReason ?? (observations == nil
                 ? "Hottest sensor per component · Measured °C, not process scores"
                 : "Hottest sensor per component · Measured °C, not process scores · Up to 3 minutes of real readings"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(RadarTheme.brand.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .radarSurface(tint: RadarTheme.brand, cornerRadius: 18)
        .help("Read-only AppleSMC temperature sensors: \(snapshot.sensorKeys.joined(separator: ", ")). No fan or power settings are changed.")
    }

    private var systemReport: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("System report", systemImage: "waveform.path")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(snapshot.systemState)
                .font(.title2.weight(.semibold))
                .foregroundStyle(snapshot.systemState == "Critical" || snapshot.systemState == "Serious" ? Color.orange : RadarTheme.brand)
            Text("macOS thermal state").font(.caption).foregroundStyle(.secondary)
            Divider()
            Label("Read-only sensors", systemImage: "checkmark.shield").font(.caption.weight(.medium))
            Text("No fan or power changes").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: observations == nil ? 100 : 142, alignment: .topLeading)
        .padding(14)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1) }
    }

    private func temperature(_ label: String, value: Double?, symbol: String, component: ThermalComponent, tint: Color, at now: Date) -> some View {
        let text = snapshot.temperatureText(value, at: now)
        let segments = observations?.segments(for: component, at: now) ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            RadarReading(text: text)
                .font(.system(size: text == "Unavailable" ? 22 : 38, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if observations != nil {
                ThermalTraceView(segments: segments, tint: tint, now: now)
                    .frame(height: 48)
            }
            Text(text == "Unavailable" ? "Waiting for a fresh reading" : observations == nil ? "Measured in Celsius" : ThermalTraceView.rangeLabel(segments))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(tint.opacity(0.13), lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) hardware temperature, \(text). \(observations == nil ? "" : ThermalTraceView.summary(segments))")
    }
}

