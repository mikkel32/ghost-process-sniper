import GhostProcessSniperCore
import SwiftUI

struct RadarConsoleSidebar: View {
    @Bindable var session: RadarConsoleSession

    var body: some View {
        List(selection: $session.state.focusedSelection) {
            Section("Radar") {
                Label("Overview", systemImage: "scope")
                    .tag(RadarFocusedSelection.overview)
            }

            ForEach(session.compactSidebarSections.filter { $0.kind != .tools }) { section in
                Section {
                    if section.rows.isEmpty {
                        Label(
                            section.kind == .attention ? "No active pressure" : "No matches",
                            systemImage: section.kind == .attention ? "checkmark.circle" : "magnifyingglass"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(section.rows.prefix(section.kind == .watched ? 14 : 8)) { row in
                            FamilyTriageSidebarRow(row: row)
                                .tag(RadarFocusedSelection.family(row.id))
                                .familyRowActions(row: row, session: session)
                        }
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text("\(section.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section("Tools") {
                Label("Duplicates", systemImage: "doc.on.doc")
                    .badge(session.monitor.consoleSnapshot.duplicateRows.count)
                    .tag(RadarFocusedSelection.duplicates)
                Label("Incidents", systemImage: "waveform.path.ecg")
                    .tag(RadarFocusedSelection.incidents)
                Label("Rules", systemImage: "slider.horizontal.3")
                    .tag(RadarFocusedSelection.rules)
                Label("Engine", systemImage: "gauge.with.dots.needle.67percent")
                    .tag(RadarFocusedSelection.engine)
            }
        }
        .listStyle(.sidebar)
        // Animate row moves only when membership/order changes, not on every
        // per-refresh metric text update.
        .animation(
            .snappy(duration: 0.32),
            value: session.compactSidebarSections.map { $0.rows.map(\.id) }
        )
    }
}

private struct FamilyTriageSidebarRow: View {
    let row: CompactSidebarRowModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: row.systemImage)
                .foregroundStyle(RadarStyle.color(for: row.level))
                .frame(width: 15)
                .symbolEffect(.pulse, options: .repeating, isActive: row.level == .critical)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ScoreCapsuleBadge(scoreText: row.scoreText, level: row.level)
                }

                HStack(spacing: 6) {
                    Text(row.subtitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.metricText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: 38)
        .help(row.helpText)
    }
}
