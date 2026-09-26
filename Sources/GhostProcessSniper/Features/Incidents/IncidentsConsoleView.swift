import AppKit
import GhostProcessSniperCore
import SwiftUI

struct IncidentsConsoleView: View {
    @Bindable var session: RadarConsoleSession
    @SceneStorage("GhostProcessSniper.Console.selectedIncident") private var storedIncidentID = ""
    @State private var tableSelection: IncidentRowViewModel.ID?

    private var selectedIncident: RadarIncident? {
        guard let tableSelection else {
            return nil
        }
        return session.monitor.incidents.first { $0.id == tableSelection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HSplitView {
                incidentTable
                    .frame(minWidth: 350)
                incidentDetail
                    .frame(minWidth: 220, idealWidth: 340)
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
                subtitle: "\(session.incidentRows.count) events shown",
                systemImage: "waveform.path.ecg",
                accent: .pink
            ) {
                InfoTip(tip: RadarTip(
                    title: "Incidents",
                    message: "The radar's memory: every time a family crosses into hot, an incident is recorded with its peak score, metrics, evidence, and timeline. Active incidents are still misbehaving; resolved ones calmed down on their own or after intervention.",
                    shortcut: "⌘3"
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
                Picker("Sort", selection: $session.state.incidentQuery.sort) {
                    ForEach(RadarIncidentSort.allCases, id: \.self) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
        }
        .padding([.top, .horizontal], 20)
        .padding(.bottom, 14)
    }

    private var incidentTable: some View {
        Table(session.incidentRows, selection: $tableSelection) {
            TableColumn("Family") { row in
                Label(row.familyName, systemImage: RadarStyle.icon(for: row.level))
                    .foregroundStyle(RadarStyle.color(for: row.level))
                    .lineLimit(1)
                    .help("\(row.leakText)\n\(row.timeRangeText)")
            }
            .width(min: 160, ideal: 220)

            TableColumn("State") { row in
                Text(row.stateText)
                    .foregroundStyle(row.stateText == "Active" ? RadarStyle.color(for: row.level) : .secondary)
            }
            .width(min: 56, ideal: 70)

            TableColumn("Score") { row in
                Text(row.scoreText)
                    .font(.body.monospacedDigit().weight(.semibold))
            }
            .width(min: 44, ideal: 52)
            .alignment(.trailing)

            TableColumn("Memory") { row in
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

            TableColumn("Hits") { row in
                Text(row.occurrenceText)
                    .font(.body.monospacedDigit())
            }
            .width(min: 40, ideal: 48)
            .alignment(.trailing)
        }
        .tableStyle(.inset)
        .overlay {
            if session.incidentRows.isEmpty {
                ContentUnavailableView(
                    "No Incidents",
                    systemImage: "checkmark.circle",
                    description: Text("Pressure spikes get logged here with their evidence and timeline.")
                )
            }
        }
    }

    @ViewBuilder
    private var incidentDetail: some View {
        if let incident = selectedIncident {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    RadarSection(title: incident.familyName, subtitle: incident.resolvedAt == nil ? "Active" : "Resolved") {
                        HStack(spacing: 8) {
                            Button {
                                session.focus(.family(incident.signature.id))
                            } label: {
                                Label("Open Family", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(incidentSummary(incident), forType: .string)
                                session.showToast("Incident copied", systemImage: "doc.on.clipboard")
                            } label: {
                                Label("Copy", systemImage: "doc.on.clipboard")
                            }
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            RadarChip(title: "Score", value: "\(Int(incident.maxScore.rounded()))", systemImage: "gauge.with.dots.needle.67percent", level: incident.level)
                            RadarChip(title: "Duration", value: incidentDuration(incident), systemImage: "clock")
                        }
                        FlowTags(title: "Why", items: incident.reasons)
                    }

                    RadarSection(title: "Metrics") {
                        HStack(spacing: 8) {
                            RadarChip(title: "Memory", value: RadarBytes.string(incident.memoryBytes), systemImage: "memorychip", level: incident.level)
                            RadarChip(title: "CPU", value: "\(Int(incident.cpuPercent.rounded()))%", systemImage: "cpu", level: incident.level)
                            RadarChip(title: "Leak", value: "\(Int(incident.leakVelocityMegabytesPerMinute.rounded())) MB/min", systemImage: "chart.line.uptrend.xyaxis", level: incident.leakVelocityMegabytesPerMinute > 0 ? .watch : .quiet)
                        }
                    }

                    RadarSection(title: "Timeline") {
                        VStack(alignment: .leading, spacing: 8) {
                            detailLine("Started", incident.startedAt.formatted(date: .abbreviated, time: .shortened))
                            detailLine("Last seen", incident.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                            detailLine("Resolved", incident.resolvedAt?.formatted(date: .abbreviated, time: .shortened) ?? "not resolved")
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

    private func incidentDuration(_ incident: RadarIncident) -> String {
        let end = incident.resolvedAt ?? incident.lastSeenAt
        let seconds = max(0, end.timeIntervalSince(incident.startedAt))
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        if seconds < 3_600 {
            return "\(Int((seconds / 60).rounded()))m"
        }
        return String(format: "%.1fh", seconds / 3_600)
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
            "Memory: \(RadarFormat.bytes(incident.memoryBytes))",
            "CPU: \(RadarFormat.percent(incident.cpuPercent))",
            "Reasons: \(incident.reasons.joined(separator: ", "))"
        ].joined(separator: "\n")
    }
}
