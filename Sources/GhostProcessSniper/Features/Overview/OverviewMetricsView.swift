import GhostProcessSniperCore
import SwiftUI

struct OverviewMetricsView: View {
    let session: RadarConsoleSession

    var body: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ForEach(session.commandCenter.chips) { chip in
                        metric(chip).frame(minWidth: 136)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(session.commandCenter.chips) { chip in
                        metric(chip)
                    }
                }
            }
            HStack(spacing: 14) {
                MemoryPressureBadge(pressure: session.monitor.systemPressure)
                Spacer(minLength: 8)
                Text("Memory totals cover tracked families")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 4)
        }
    }

    private func metric(_ chip: FamilyMetricCard) -> some View {
        Button { openMetric(chip.title) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: chip.systemImage)
                        .foregroundStyle(RadarTheme.accent(for: chip.level))
                        .frame(width: 25, height: 25)
                        .background(RadarTheme.accent(for: chip.level).opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    Text(chip.title == "Hot" ? "Needs review" : chip.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                .font(.caption.weight(.medium))

                RadarReading(text: chip.value)
                    .font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 5) {
                    Text(actionTitle(chip.title))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .radarSurface(tint: RadarTheme.accent(for: chip.level), cornerRadius: 16)
        }
        .buttonStyle(RadarCardButtonStyle(tint: RadarTheme.accent(for: chip.level)))
        .accessibilityLabel("\(chip.title), \(chip.value). \(actionTitle(chip.title))")
    }

    private func actionTitle(_ title: String) -> String {
        switch title {
        case "Families": "Browse all"
        case "Hot": "Review activity"
        case "Leaks": "Inspect growth"
        case "Duplicates": "Review overlaps"
        case "Memory": "Largest first"
        default: "Engine health"
        }
    }

    private func openMetric(_ title: String) {
        switch title {
        case "Families": session.browseFamilies()
        case "Hot": session.browseFamilies(filter: .attention)
        case "Leaks": session.browseFamilies(filter: .leaking)
        case "Duplicates": session.focus(.duplicates)
        case "Memory": session.browseFamilies(sort: .memory)
        default: session.focus(.engine)
        }
    }
}
