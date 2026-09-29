import GhostProcessSniperCore
import SwiftUI

struct OverviewMetricsView: View {
    let session: RadarConsoleSession

    private static let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(session.commandCenter.chips) { chip in
                    if chip.destination == .memory {
                        MemoryMetricCard(chip: chip, session: session)
                    } else {
                        OverviewMetricCard(chip: chip, level: chip.level) {
                            session.openMetric(chip.destination)
                        }
                    }
                }
            }
            OverviewPressureRow(monitor: session.monitor)
        }
    }
}

/// The only card that reads host memory pressure, so a pressure change
/// redraws this card rather than the whole grid.
private struct MemoryMetricCard: View {
    let chip: FamilyMetricCard
    let session: RadarConsoleSession

    var body: some View {
        OverviewMetricCard(chip: chip, level: session.monitor.systemPressure.level.ghostLevel) {
            session.openMetric(chip.destination)
        }
    }
}

private struct OverviewPressureRow: View {
    let monitor: ProcessMonitor

    var body: some View {
        HStack(spacing: 14) {
            MemoryPressureBadge(pressure: monitor.systemPressure)
            Spacer(minLength: 8)
            Text("Memory totals cover tracked families")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 4)
    }
}

private struct OverviewMetricCard: View {
    let chip: FamilyMetricCard
    let level: GhostLevel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: chip.systemImage)
                        .foregroundStyle(RadarTheme.accent(for: level))
                        .frame(width: 25, height: 25)
                        .background(RadarTheme.accent(for: level).opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    Text(chip.title)
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
                    Text(chip.actionTitle ?? "")
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
            .radarSurface(tint: RadarTheme.accent(for: level), cornerRadius: 16)
        }
        .buttonStyle(RadarCardButtonStyle(tint: RadarTheme.accent(for: level)))
        .accessibilityLabel("\(chip.title), \(chip.value). \(chip.actionTitle ?? "")")
    }
}

private extension RadarConsoleSession {
    func openMetric(_ destination: OverviewMetricDestination?) {
        guard let destination else { return }
        switch destination {
        case .duplicates: focus(.duplicates)
        case .memory: browseFamilies(sort: .memory)
        case .families, .review, .leaking: browseFamilies(filter: destination.filter ?? .all)
        }
    }
}
