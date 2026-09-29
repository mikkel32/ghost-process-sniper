import GhostProcessSniperCore
import SwiftUI

/// In the popover: the top energy finding when there is one, otherwise the
/// battery line while on battery, otherwise nothing. Observes only the glance,
/// which changes when a rounded figure or a finding changes.
struct PopoverEnergyRow: View {
    let monitor: ProcessMonitor
    let onOpen: () -> Void

    var body: some View {
        let glance = monitor.energyGlance
        if let finding = glance.topFinding {
            let tint = EnergyStyle.color(for: finding.severity)
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: EnergyStyle.symbol(for: finding.kind))
                        .font(.title3)
                        .foregroundStyle(tint.gradient)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.headline)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(glance.findings.count > 1 ? "\(glance.findings.count) energy findings" : finding.advice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("Review")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                .padding(10)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.75) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Energy: \(finding.headline). Review")
        } else if glance.isDischarging, let line = glance.batteryLine {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "battery.75percent")
                        .foregroundStyle(.green)
                    Text(line)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let name = glance.topConsumerName, let watts = glance.topConsumerWatts {
                        Text("\(name) \(EnergyFormat.watts(watts))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption.monospacedDigit().weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .radarSurface(tint: .green, cornerRadius: 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Energy")
        }
    }
}
