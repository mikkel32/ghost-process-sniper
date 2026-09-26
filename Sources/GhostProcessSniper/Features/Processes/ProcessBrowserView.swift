import GhostProcessSniperCore
import SwiftUI

struct ProcessBrowserView: View {
    @Bindable var session: RadarConsoleSession

    private var hasFilters: Bool {
        !session.state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.state.familyFilter != .all
    }

    var body: some View {
        browserContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .radarEntrance()
    }

    private var browserContent: some View {
        let items = session.familyItems
        let search = session.searchResults
        let others = search.processRows
        let familyCount = session.monitor.summary.familyCount
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(search.isActive ? "Search results" : "All processes")
                            .font(.largeTitle.weight(.bold))
                        Text(search.isActive
                             ? "Tracked families first, then everything else that is running. Return opens the best match."
                             : "Find what is using your Mac. Select a family to understand its activity.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Text(search.isActive ? "\(items.count) tracked \u{00b7} \(search.processMatchCount) other" : "\(items.count) of \(familyCount)")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RadarTheme.brand.opacity(0.1), in: Capsule())
                        .accessibilityLabel(search.isActive
                            ? "\(items.count) tracked families and \(search.processMatchCount) other processes match"
                            : "\(items.count) matching families out of \(familyCount)")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        filters
                        Spacer(minLength: 8)
                        sortPicker(relevance: search.query.ranksByRelevance)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        filters
                        sortPicker(relevance: search.query.ranksByRelevance)
                    }
                }

                ProcessSearchSummary(session: session)
            }
            .padding(24)

            if items.isEmpty && others.isEmpty && session.queries.isUpdating {
                ProgressView(search.isActive ? "Searching" : "Preparing process list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && others.isEmpty {
                ContentUnavailableView {
                    Label(hasFilters ? "No matching processes" : "Waiting for processes", systemImage: hasFilters ? "magnifyingglass" : "waveform.path")
                } description: {
                    Text(hasFilters
                         ? "Nothing running matches. Check the spelling, remove a filter, or search by PID or port."
                         : session.monitor.storeError ?? "The next scan will populate this list.")
                } actions: {
                    if hasFilters {
                        Button("Show All Processes") { session.clearFamilyFilters() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Scan Now") { session.refresh() }
                            .disabled(session.isRefreshing)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                columnHeadings
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if items.isEmpty {
                            Text("No tracked family matches.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        ForEach(items) { item in
                            let match = search.familyMatches[item.id]
                            Button { session.focus(.family(item.id)) } label: {
                                ProcessBrowserRow(item: item, match: match)
                                    .equatable()
                            }
                            .buttonStyle(RadarRowButtonStyle())
                            .familyRowActions(row: CompactSidebarRowModel(item: item), session: session)
                            .accessibilityLabel("\(item.displayName), \(item.assessment.status), \(match?.reason ?? item.assessment.cause), memory \(item.memoryText), CPU \(item.cpuText)")
                            .accessibilityHint("Open process details")
                        }
                        if !others.isEmpty {
                            UntrackedProcessSection(session: session, rows: others, hiddenCount: search.hiddenProcessCount)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .accessibilityHidden(true)
                Text("A family groups related processes. Opening a row only shows details.")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(RadarTheme.panel)
        }
        .background(RadarTheme.canvas)
    }

    private var filters: some View {
        ProcessFilterBar(session: session)
    }

    private func sortPicker(relevance: Bool) -> some View {
        Picker("Sort", selection: $session.state.familySort) {
            ForEach(RadarSort.allCases, id: \.self) { sort in
                Text(sort == .smart ? (relevance ? "Best match" : "Priority") : sort.label).tag(sort)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 160)
    }

    /// Column titles double as sort controls; clicking the active one
    /// returns to priority order.
    private var columnHeadings: some View {
        HStack(spacing: 14) {
            sortHeading("PROCESS FAMILY", sort: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeading("MEMORY", sort: .memory)
                .frame(width: 84, alignment: .trailing)
            sortHeading("CPU", sort: .cpu)
                .frame(width: 64, alignment: .trailing)
            Text("ACTION")
                .frame(width: 74, alignment: .trailing)
                .accessibilityHidden(true)
            Color.clear.frame(width: 12, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 30)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.025))
        .accessibilityElement(children: .contain)
    }

    private func sortHeading(_ title: String, sort: RadarSort) -> some View {
        let isActive = session.state.familySort == sort
        return Button {
            session.state.familySort = isActive ? .smart : sort
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: sort == .name ? "chevron.up" : "chevron.down")
                    .opacity(isActive ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "Back to priority order" : "Sort by \(sort.label.lowercased())")
        .accessibilityLabel("Sort by \(sort.label)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct ProcessBrowserRow: View, Equatable {
    let item: FamilyTriageViewModel
    let match: ProcessSearchMatch?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.item, b = rhs.item
        return a.id == b.id && a.displayName == b.displayName && a.level == b.level &&
            a.assessment.cause == b.assessment.cause && a.assessment.status == b.assessment.status &&
            a.memoryText == b.memoryText && a.cpuText == b.cpuText &&
            lhs.match?.nameHighlights == rhs.match?.nameHighlights && lhs.match?.reason == rhs.match?.reason
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: RadarStyle.icon(for: item.level))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(RadarTheme.accent(for: item.level))
                    .frame(width: 36, height: 36)
                    .background(RadarTheme.accent(for: item.level).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    HighlightedText(text: item.displayName, highlights: match?.nameHighlights ?? [])
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let reason = match?.reason {
                        Label(reason, systemImage: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(RadarTheme.brand)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(item.assessment.cause)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.memoryText).frame(width: 84, alignment: .trailing)
            Text(item.cpuText).frame(width: 64, alignment: .trailing)
            Text(item.assessment.status)
                .fontWeight(.semibold)
                .foregroundStyle(RadarTheme.accent(for: item.level))
                .frame(width: 74, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct RadarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(RadarTheme.brand.opacity(configuration.isPressed ? 0.15 : isHovering ? 0.07 : 0))
                        .animation(RadarMotion.response(reduceMotion), value: isHovering)
                        .animation(RadarMotion.response(reduceMotion), value: configuration.isPressed)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(RadarTheme.brand.opacity(configuration.isPressed ? 0.4 : isHovering ? 0.22 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                        .animation(RadarMotion.response(reduceMotion), value: isHovering)
                }
                .onHover { isHovering = $0 }
        }
    }
}
