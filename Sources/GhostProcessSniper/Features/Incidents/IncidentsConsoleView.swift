import GhostProcessSniperCore
import SwiftUI

struct IncidentsConsoleView: View {
    @Bindable var session: RadarConsoleSession
    @SceneStorage("GhostProcessSniper.Console.selectedIncident") private var storedIncidentID = ""
    @State private var tableSelection: IncidentRowViewModel.ID?

    /// The displayed row, then the full incident behind it for the timeline.
    private var selection: (row: IncidentRowViewModel, incident: RadarIncident)? {
        guard let tableSelection, let row = session.incidentRows.first(where: { $0.id == tableSelection }),
              let incident = session.incident(id: row.id) else {
            return nil
        }
        return (row, incident)
    }

    private var hasQuery: Bool {
        !session.state.incidentQuery.text.isEmpty || session.state.incidentQuery.filter != .all
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.incidentRows.isEmpty, session.isSearchingIncidentLog {
                // The window found nothing, but the whole log has not answered yet.
                ContentUnavailableView(
                    "Searching Incidents",
                    systemImage: "magnifyingglass",
                    description: Text("Reading every recorded incident.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.incidentRows.isEmpty {
                ContentUnavailableView(
                    hasQuery ? "No Matching Incidents" : "No Incidents",
                    systemImage: hasQuery ? "magnifyingglass" : "checkmark.circle",
                    description: Text(hasQuery
                        ? "Nothing logged matches this search or filter."
                        : "Pressure spikes get logged here with their evidence and timeline.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    incidentTable
                        .frame(minWidth: 350)
                    incidentDetail
                        .frame(minWidth: 220, idealWidth: 340)
                }
            }
        }
        .onAppear {
            if let restored = UUID(uuidString: storedIncidentID) {
                tableSelection = restored
            }
            stabilizeSelection()
        }
        .onChange(of: tableSelection) { _, selection in
            storedIncidentID = selection?.uuidString ?? ""
        }
        .onChange(of: session.incidentRows.map(\.id)) { _, _ in
            stabilizeSelection()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            RadarPageHeader(
                eyebrow: "Evidence Log",
                title: "Incidents",
                subtitle: session.incidentScope.caption(
                    shown: session.incidentRows.count,
                    query: session.state.incidentQuery,
                    isLoadingHistory: session.isSearchingIncidentLog
                ),
                systemImage: "waveform.path.ecg",
                accent: .pink
            ) {
                InfoTip(tip: RadarTip(
                    title: "Incidents",
                    message: "The radar's memory: every time a family crosses into hot, an incident is recorded with its peak score, metrics, evidence, and timeline. Active incidents are still misbehaving; resolved ones calmed down on their own or after intervention.",
                    shortcut: "⌘6"
                ))
                Button {
                    session.copyReport()
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
            }

            HStack(spacing: 10) {
                TextField("Search incidents", text: $session.state.incidentQuery.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Picker("Filter", selection: $session.state.incidentQuery.filter) {
                    ForEach(RadarIncidentFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
        }
        .padding([.top, .horizontal], 20)
        .padding(.bottom, 14)
    }

    private var incidentTable: some View {
        Table(session.incidentRows, selection: $tableSelection, sortOrder: sortOrder) {
            TableColumn("Family", value: \.familyName) { row in
                HStack(spacing: 6) {
                    // The name comes first: a capsule beside it cut "Safari" to "Saf…".
                    Label(row.familyName, systemImage: RadarStyle.icon(for: row.level))
                        .foregroundStyle(RadarStyle.color(for: row.level))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if row.liveFamilyKey != nil {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                            .help("Running now")
                            .accessibilityLabel("Running now")
                    }
                }
                .help("Peak growth: \(row.leakText)\n\(row.timeRangeText)")
            }
            .width(min: 170, ideal: 230)

            TableColumn("State") { row in
                Text(row.stateText)
                    .foregroundStyle(row.isActive ? RadarStyle.color(for: row.level) : .secondary)
            }
            .width(min: 56, ideal: 70)

            TableColumn("Score", value: \.score) { row in
                Text(row.scoreText)
                    .font(.body.monospacedDigit().weight(.semibold))
            }
            .width(min: 44, ideal: 52)
            .alignment(.trailing)

            TableColumn("Memory", value: \.memoryBytes) { row in
                Text(row.memoryText)
                    .font(.body.monospacedDigit())
            }
            .width(min: 64, ideal: 76)
            .alignment(.trailing)

            TableColumn("CPU") { row in
                Text(row.cpuText)
                    .font(.body.monospacedDigit())
            }
            .width(min: 44, ideal: 52)
            .alignment(.trailing)

            TableColumn("Hits", value: \.occurrenceCount) { row in
                Text(row.occurrenceText)
                    .font(.body.monospacedDigit())
            }
            .width(min: 40, ideal: 48)
            .alignment(.trailing)
        }
        .tableStyle(.inset)
    }

    /// Column headers drive the incident query; most recent first has no column.
    private var sortOrder: Binding<[KeyPathComparator<IncidentRowViewModel>]> {
        let state = session.state
        return Binding(
            get: {
                let order: SortOrder = state.incidentQuery.ascending ? .forward : .reverse
                switch state.incidentQuery.sort {
                case .name: return [KeyPathComparator(\IncidentRowViewModel.familyName, order: order)]
                case .severity: return [KeyPathComparator(\IncidentRowViewModel.score, order: order)]
                case .memory: return [KeyPathComparator(\IncidentRowViewModel.memoryBytes, order: order)]
                case .recurrence: return [KeyPathComparator(\IncidentRowViewModel.occurrenceCount, order: order)]
                case .recent: return []
                }
            },
            set: { comparators in
                let first = comparators.first
                state.incidentQuery.ascending = first?.order == .forward
                state.incidentQuery.sort = RadarIncidentSort(incidentColumn: first?.keyPath)
                session.scheduleQueryUpdate()
            }
        )
    }

    @ViewBuilder
    private var incidentDetail: some View {
        if let selected = selection {
            let row = selected.row
            let incident = selected.incident
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    RadarSection(title: incident.familyName, subtitle: row.liveFamilyKey == nil ? "\(row.stateText) · exited" : "\(row.stateText) · running") {
                        HStack(spacing: 8) {
                            if let liveKey = row.liveFamilyKey {
                                Button("Open Family", systemImage: "arrow.up.right.square") {
                                    session.focus(.family(liveKey))
                                }
                                .buttonStyle(.borderedProminent)
                                if row.isActive {
                                    Button("Stop\u{2026}", systemImage: "stop.circle", role: .destructive) {
                                        session.prepareKill(familyKey: liveKey)
                                    }
                                }
                            } else {
                                Button("Search for It", systemImage: "magnifyingglass") {
                                    session.addSearchToken(incident.familyName)
                                }
                                .help("The family has exited; search for a new copy of it")
                            }

                            Button("Copy", systemImage: "doc.on.clipboard") {
                                session.copyToPasteboard(incidentSummary(incident), toast: "Incident copied")
                            }
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            RadarChip(title: "Score", value: "\(Int(incident.maxScore.rounded()))", systemImage: "gauge.with.dots.needle.67percent", level: incident.level)
                            RadarChip(title: "Duration", value: row.durationText, systemImage: "clock")
                        }
                        FlowTags(title: "Why", items: incident.reasons)
                    }

                    // Every value is the episode's highest, not the last sample.
                    RadarSection(title: "Metrics", subtitle: "Peak values") {
                        HStack(spacing: 8) {
                            RadarChip(title: "Memory", value: row.memoryText, systemImage: "memorychip", level: incident.level)
                            RadarChip(title: "CPU", value: row.cpuText, systemImage: "cpu", level: incident.level)
                            RadarChip(title: "Growth", value: row.leakText, systemImage: "chart.line.uptrend.xyaxis", level: IncidentRowViewModel.hasGrowth(incident.leakVelocityMegabytesPerMinute) ? .watch : .quiet)
                        }
                    }

                    RadarSection(title: "Timeline") {
                        VStack(alignment: .leading, spacing: 8) {
                            detailLine("Started", incident.startedAt.formatted(date: .abbreviated, time: .shortened))
                            detailLine("Last seen", incident.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                            detailLine("Resolved", incident.resolvedAt?.formatted(date: .abbreviated, time: .shortened) ?? "not resolved")
                        }
                    }

                    // Facts about the app's other episodes, never a verdict: the scorer counts a repeat against a family.
                    if let recurrence = row.recurrence {
                        RadarSection(title: "Recurrence", subtitle: "Same app and command") {
                            VStack(alignment: .leading, spacing: 8) {
                                detailLine("Episodes", recurrence.episodesText)
                                if let length = recurrence.lengthText {
                                    detailLine("Typical length", length)
                                }
                                detailLine("Peak memory", recurrence.peakText)
                            }
                        }
                    }
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView(
                "Select an Incident",
                systemImage: "waveform.path.ecg",
                description: Text("Pick a row to see its evidence, metrics, and timeline.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .font(.caption)
    }

    private func stabilizeSelection() {
        let validIDs = Set(session.incidentRows.map(\.id))
        if let tableSelection, validIDs.contains(tableSelection) {
            return
        }
        tableSelection = session.incidentRows.first?.id
    }

    private func incidentSummary(_ incident: RadarIncident) -> String {
        [
            "Ghost Process Sniper Incident",
            "Family: \(incident.familyName)",
            "State: \(incident.resolvedAt == nil ? "Active" : "Resolved")",
            "Score: \(Int(incident.maxScore.rounded()))",
            "Peak memory: \(RadarFormat.bytes(incident.memoryBytes))",
            "Peak CPU: \(RadarFormat.percent(incident.cpuPercent))",
            "Peak growth: \(IncidentRowViewModel.growthText(incident.leakVelocityMegabytesPerMinute))",
            "Reasons: \(incident.reasons.joined(separator: ", "))"
        ].joined(separator: "\n")
    }
}
