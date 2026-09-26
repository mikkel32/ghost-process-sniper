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
    }

    private var browserContent: some View {
        let items = session.familyItems
        let search = session.searchResults
        let rows = session.browserRows
        let familyCount = session.monitor.summary.familyCount
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(search.isActive ? "Search results" : "All processes")
                            .font(.largeTitle.weight(.bold))
                        Text(search.isActive
                             ? "Tracked families first, then everything else that is running. Return opens the best match."
                             : "Find what is using your Mac. Double-click a family to understand its activity.")
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
                        ProcessFilterBar(session: session)
                        Spacer(minLength: 8)
                        sortPicker(relevance: search.query.ranksByRelevance)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ProcessFilterBar(session: session)
                        sortPicker(relevance: search.query.ranksByRelevance)
                    }
                }

                ProcessSearchSummary(session: session)
            }
            .padding(24)

            if rows.isEmpty && session.queries.isUpdating {
                ProgressView(search.isActive ? "Searching" : "Preparing process list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label(hasFilters ? "No matching processes" : "Waiting for processes", systemImage: hasFilters ? "magnifyingglass" : "waveform.path")
                } description: {
                    // A failed projection would otherwise leave this empty state unexplained.
                    Text(session.queries.errorMessage.map { "The list could not be updated: \($0)" }
                         ?? (hasFilters
                             ? "Nothing running matches. Check the spelling, remove a filter, or search by PID or port."
                             : session.monitor.storeError ?? "The next scan will populate this list."))
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
                ProcessBrowserTable(rows: rows, session: session)
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .accessibilityHidden(true)
                if search.hiddenProcessCount > 0 {
                    Text("\(search.hiddenProcessCount) more running processes match \u{2014} add words or filters to narrow the search.")
                } else if search.isActive, !search.processRows.isEmpty {
                    Text("Untracked processes are outside the \u{201c}\(session.monitor.settings.radarMode.userLabel)\u{201d} scope, so they have no trend or verdict.")
                } else {
                    Text("A family groups related processes. Right-click a row to stop, snooze or copy it.")
                }
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

    private func sortPicker(relevance: Bool) -> some View {
        Picker("Sort", selection: Binding(
            get: { session.state.familySort },
            set: { sort in
                session.state.familySortInNaturalDirection = sort
                session.scheduleQueryUpdate()
            }
        )) {
            ForEach(RadarSort.allCases, id: \.self) { sort in
                Text(sort == .smart ? (relevance ? "Best match" : "Priority") : sort.label).tag(sort)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 160)
    }
}
