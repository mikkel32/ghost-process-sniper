import GhostProcessSniperCore
import SwiftUI

struct RadarConsoleSidebar: View {
    let session: RadarConsoleSession
    @Namespace private var destinationNamespace

    private var hasQueryFilters: Bool {
        !session.state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.state.familyFilter != .all
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            VStack(spacing: 5) {
                destination("Overview", subtitle: "Your Mac at a glance", image: "square.grid.2x2", selection: .overview)
                destination("All Processes", subtitle: "Search and explore every family", image: "list.bullet.rectangle", selection: .processes)
            }
            .padding(10)

            if hasQueryFilters {
                HStack {
                    Label(session.state.searchText.isEmpty ? session.state.familyFilter.label : "\u{201c}\(session.state.searchText)\u{201d}", systemImage: "line.3.horizontal.decrease")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Clear") { session.clearFamilyFilters() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(session.compactSidebarSections) { section in
                        SidebarSectionHeader(title: section.title, count: section.count)
                            .padding(.horizontal, 7)
                            .padding(.top, 12)

                        if section.rows.isEmpty {
                            Label(
                                section.kind == .attention && !hasQueryFilters ? "No active pressure" : "No matching families",
                                systemImage: section.kind == .attention && !hasQueryFilters ? "checkmark.circle" : "magnifyingglass"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                        } else {
                            ForEach(section.rows.prefix(section.kind == .watched ? 10 : 6)) { row in
                                Button {
                                    session.focus(.family(row.id))
                                } label: {
                                    FamilyTriageSidebarRow(
                                        row: row,
                                        isSelected: session.state.focusedSelection == .family(row.id)
                                    )
                                }
                                .buttonStyle(RadarRowButtonStyle())
                                .accessibilityAddTraits(session.state.focusedSelection == .family(row.id) ? .isSelected : [])
                                .familyRowActions(row: row, session: session)
                            }
                            if section.rows.count > (section.kind == .watched ? 10 : 6) {
                                Button {
                                    if hasQueryFilters {
                                        session.focus(.processes)
                                    } else {
                                        // Stable is exactly the complement of Attention.
                                        session.browseFamilies(filter: section.kind == .attention ? .attention : .quiet)
                                    }
                                } label: {
                                    HStack {
                                        Text(hasQueryFilters ? "Browse all matches" : "View all \(section.count)")
                                        Spacer()
                                        Image(systemName: "arrow.right")
                                    }
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(RadarTheme.brand)
                            }
                        }
                    }
                }
            }
            .contentMargins(.horizontal, 10, for: .scrollContent)
            .contentMargins(.vertical, 8, for: .scrollContent)

            sidebarTools
            HStack {
                Button {
                    session.openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Spacer()
                Button {
                    session.showQuickGuide = true
                } label: {
                    Label("Guide", systemImage: "questionmark.circle")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background {
            LinearGradient(
                colors: [RadarTheme.brand.opacity(0.045), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    private func destination(_ title: String, subtitle: String, image: String, selection: RadarFocusedSelection) -> some View {
        Button { session.focus(selection) } label: {
            SidebarDestinationRow(
                title: title,
                subtitle: subtitle,
                systemImage: image,
                color: RadarTheme.brand,
                isSelected: session.state.focusedSelection == selection
            )
            .background {
                RadarSelectionSurface(selected: session.state.focusedSelection == selection,
                                      namespace: destinationNamespace, key: "main-destination")
            }
        }
        .buttonStyle(RadarRowButtonStyle())
        .accessibilityAddTraits(session.state.focusedSelection == selection ? .isSelected : [])
    }

    private var sidebarTools: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            SidebarToolButton(
                title: "Duplicates",
                systemImage: "square.on.square",
                color: .orange,
                badge: "\(session.monitor.consoleSnapshot.duplicateRows.count)",
                isSelected: session.state.focusedSelection == .duplicates
            ) { session.focus(.duplicates) }
            SidebarToolButton(
                title: "Incidents",
                systemImage: "waveform.path.ecg",
                color: .pink,
                badge: nil,
                isSelected: session.state.focusedSelection == .incidents
            ) { session.focus(.incidents) }
            SidebarToolButton(
                title: "Rules",
                systemImage: "slider.horizontal.3",
                color: .purple,
                badge: nil,
                isSelected: session.state.focusedSelection == .rules
            ) { session.focus(.rules) }
            SidebarToolButton(
                title: "Engine",
                systemImage: "gauge.with.dots.needle.67percent",
                color: .teal,
                badge: nil,
                isSelected: session.state.focusedSelection == .engine
            ) { session.focus(.engine) }
        }
        .padding(10)
        .background(RadarTheme.panel)
        .overlay(alignment: .top) { Divider() }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 11) {
            RadarBrandMark(level: .quiet, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ghost Radar")
                    .font(.headline.weight(.bold))
                Text(session.commandCenter.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RadarTheme.accent(for: session.commandCenter.level))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Circle()
                .fill(RadarTheme.accent(for: session.commandCenter.level))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}

private struct SidebarToolButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let badge: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(badge.map { "\(title): \($0)" } ?? title)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct SidebarDestinationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }
}

private struct FamilyTriageSidebarRow: View {
    let row: CompactSidebarRowModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(RadarTheme.accent(for: row.level).gradient)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: row.systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(RadarTheme.accent(for: row.level))
                    Text(row.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ScoreCapsuleBadge(scoreText: row.statusText, level: row.level)
                }

                HStack(spacing: 6) {
                    Text(row.subtitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(row.metricText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .frame(minHeight: 58)
        .background(
            isSelected ? RadarTheme.accent(for: row.level).opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(Rectangle())
        .help(row.helpText)
    }
}
