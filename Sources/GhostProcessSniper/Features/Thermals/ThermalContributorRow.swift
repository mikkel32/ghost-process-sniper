import GhostProcessSniperCore
import SwiftUI

struct ThermalContributorRow: View {
    let contributor: ThermalContributor
    let isLeading: Bool
    let now: Date
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cpuText: String {
        isCurrent(contributor.cpuMeasuredAt) ? ThermalActivityFormat.percent(contributor.cpuPercent) : "Unavailable"
    }

    private var gpuText: String {
        isCurrent(contributor.gpuMeasuredAt) ? ThermalActivityFormat.percent(contributor.gpuPercent) : "Unreported"
    }

    private func isCurrent(_ date: Date?) -> Bool {
        guard let date else { return false }
        return (0...ThermalActivitySummary.maximumAge).contains(now.timeIntervalSince(date))
    }

    private var busiestProcess: ThermalProcessEvidence? {
        contributor.processes.filter { isCurrent($0.cpuMeasuredAt) || isCurrent($0.gpuMeasuredAt) }
            .max {
                max(isCurrent($0.cpuMeasuredAt) ? $0.cpuPercent : 0,
                    isCurrent($0.gpuMeasuredAt) ? $0.gpuPercent : 0) <
                max(isCurrent($1.cpuMeasuredAt) ? $1.cpuPercent : 0,
                    isCurrent($1.gpuMeasuredAt) ? $1.gpuPercent : 0)
            }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                identity.frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                meters.frame(width: 320)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                identity
                meters
            }
        }
        .padding(12)
        .background(RadarTheme.brand.opacity(isHovered ? 0.095 : isLeading ? 0.05 : 0.018),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(RadarTheme.brand.opacity(isLeading ? 0.25 : isHovered ? 0.18 : 0.07), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(contributor.displayName), CPU \(cpuText) where 100 percent is one logical core, reported GPU \(gpuText), \(contributor.processCount) processes. Inspect activity.")
    }

    private var identity: some View {
        HStack(spacing: 12) {
            ThermalAppIcon(path: contributor.applicationPath, isSystemProcess: contributor.isSystemProcess)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(contributor.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                    if isLeading {
                        Text("TOP").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(RadarTheme.brand)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RadarTheme.brand.opacity(0.12), in: Capsule())
                    }
                }
                Text(contributor.isSystemProcess ? "macOS service" :
                     "\(contributor.processCount) \(contributor.processCount == 1 ? "process" : "processes")")
                    .font(.caption).foregroundStyle(.secondary)
                if let busiest = busiestProcess {
                    Text("Top sampled process: \(busiest.name)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var meters: some View {
        HStack(spacing: 18) {
            ThermalActivityMeter(title: "CPU", value: isCurrent(contributor.cpuMeasuredAt) ? contributor.cpuPercent : nil,
                detail: !isCurrent(contributor.cpuMeasuredAt) ? "No current CPU reading" :
                    "\(ThermalActivityFormat.percent(contributor.cpuCapacityPercent)) of all cores",
                tint: RadarTheme.brand)
            ThermalActivityMeter(title: "Reported GPU", value: isCurrent(contributor.gpuMeasuredAt) ? contributor.gpuPercent : nil,
                detail: !isCurrent(contributor.gpuMeasuredAt) ? "No current GPU reading" : "Process activity",
                tint: RadarTheme.brandSecondary)
        }
    }
}

private struct ThermalActivityMeter: View {
    let title: String
    let value: Double?
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value.map(ThermalActivityFormat.percent) ?? "Unavailable")
                    .monospacedDigit().fontWeight(.medium)
            }
            .font(.caption)
            if let value {
                ProgressView(value: min(1, max(0, value / 100)))
                    .tint(tint).progressViewStyle(.linear)
                    .accessibilityHidden(true)
            } else {
                Capsule().fill(.quaternary).frame(height: 4).accessibilityHidden(true)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
