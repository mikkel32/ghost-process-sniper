import GhostProcessSniperCore
import SwiftUI

/// Tracked families and untracked search matches in one native table:
/// every column sorts both ways, rows multi-select, arrow keys move,
/// Return or a double-click opens a family, and Delete previews a stop.
struct ProcessBrowserTable: View {
    let rows: [ProcessBrowserRowModel]
    let session: RadarConsoleSession

    @State private var selection: Set<ProcessBrowserRowModel.ID> = []

    var body: some View {
        Table(rows, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.name) { row in
                ProcessBrowserNameCell(row: row)
            }
            .width(min: 220, ideal: 340)

            TableColumn("Memory", value: \.memoryBytes) { row in
                Text(row.memoryText)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 84)
            .alignment(.trailing)

            TableColumn("CPU", value: \.cpuPercent) { row in
                Text(row.cpuText)
                    .monospacedDigit()
            }
            .width(min: 48, ideal: 60)
            .alignment(.trailing)

            TableColumn("Status", value: \.statusRank) { row in
                Text(row.statusText)
                    .fontWeight(row.isTracked ? .semibold : .regular)
                    .foregroundStyle(row.level.map { RadarTheme.accent(for: $0) } ?? Color.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("PID") { row in
                Text(String(row.pid))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64)
            .alignment(.trailing)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: ProcessBrowserRowModel.ID.self) { ids in
            ProcessBrowserRowMenu(rows: selectedRows(ids), session: session)
        } primaryAction: { ids in
            let selected = selectedRows(ids)
            if selected.count == 1, let key = selected.first?.familyKey {
                session.focus(.family(key))
            }
        }
        .onDeleteCommand {
            let selected = selectedRows(selection)
            if selected.count == 1, let row = selected.first {
                ProcessBrowserRowMenu.stop(row, session: session)
            }
        }
    }

    private func selectedRows(_ ids: Set<ProcessBrowserRowModel.ID>) -> [ProcessBrowserRowModel] {
        guard !ids.isEmpty else { return [] }
        return rows.filter { ids.contains($0.id) }
    }

    /// Table headers read and write the console's sort, so the Sort menu,
    /// the headers and the projection always agree.
    private var sortOrder: Binding<[KeyPathComparator<ProcessBrowserRowModel>]> {
        let state = session.state
        let session = session
        return Binding(
            get: {
                let order: SortOrder = state.familySortAscending ? .forward : .reverse
                switch state.familySort {
                case .smart: return [KeyPathComparator(\ProcessBrowserRowModel.statusRank, order: order)]
                case .memory: return [KeyPathComparator(\ProcessBrowserRowModel.memoryBytes, order: order)]
                case .cpu: return [KeyPathComparator(\ProcessBrowserRowModel.cpuPercent, order: order)]
                case .name: return [KeyPathComparator(\ProcessBrowserRowModel.name, order: order)]
                // Leak has no column; it stays reachable from the Sort menu.
                case .leak: return []
                }
            },
            set: { comparators in
                let first = comparators.first
                state.familySortAscending = first?.order == .forward
                state.familySort = RadarSort(browserColumn: first?.keyPath)
                session.scheduleQueryUpdate()
            }
        )
    }
}

private struct ProcessBrowserNameCell: View {
    let row: ProcessBrowserRowModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.level.map { RadarStyle.icon(for: $0) } ?? "app.dashed")
                .font(.body.weight(.semibold))
                .foregroundStyle(row.level.map { RadarTheme.accent(for: $0) } ?? Color.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HighlightedText(text: row.name, highlights: row.nameHighlights)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(row.commandLine.isEmpty ? row.executablePath : row.commandLine)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.isTracked ? row.statusText : "not tracked"), \(row.detail)")
    }
}

/// The menu for the selected rows: a single row can be stopped, opened,
/// copied or revealed; several tracked families can be snoozed or ignored.
private struct ProcessBrowserRowMenu: View {
    let rows: [ProcessBrowserRowModel]
    let session: RadarConsoleSession

    var body: some View {
        let tracked = rows.compactMap { row in row.familyKey.map { (key: $0, name: row.name) } }
        if rows.count == 1, let row = rows.first {
            if let key = row.familyKey {
                Button("Show Details", systemImage: "sidebar.right") { session.focus(.family(key)) }
                Divider()
            }
            Button(StopActionLabel.title(risk: nil, memberCount: 1), systemImage: "stop.circle", role: .destructive) {
                Self.stop(row, session: session)
            }
            .disabled(!row.isStoppable)
            .help(row.isStoppable ? "Preview exactly what will be stopped, then confirm" : "Owned by another user or the system")
        }
        if !tracked.isEmpty {
            Menu {
                FamilySnoozeMenu { minutes in session.snooze(families: tracked, minutes: minutes) }
            } label: {
                Label(tracked.count > 1 ? "Snooze \(tracked.count) Families" : "Snooze", systemImage: "moon")
            }
            Button(tracked.count > 1 ? "Ignore \(tracked.count) Families" : "Ignore Family", systemImage: "eye.slash") {
                session.ignore(families: tracked)
            }
        }
        Divider()
        Button(rows.count == 1 ? "Copy PID" : "Copy \(rows.count) PIDs", systemImage: "number") {
            session.copyPIDs(rows.map(\.pid))
        }
        if rows.count == 1, let row = rows.first {
            Button("Copy Command Line", systemImage: "terminal") {
                session.copyToPasteboard(row.commandLine, toast: "Copied command line")
            }
            .disabled(row.commandLine.isEmpty)
            Button("Reveal in Finder", systemImage: "folder") {
                session.revealInFinder(executablePath: row.executablePath)
            }
            .disabled(row.executablePath.isEmpty)
        }
    }

    @MainActor
    static func stop(_ row: ProcessBrowserRowModel, session: RadarConsoleSession) {
        guard row.isStoppable else { return }
        if let key = row.familyKey {
            session.prepareKill(familyKey: key)
        } else {
            session.prepareKill(processIdentity: row.identity, name: row.name)
        }
    }
}
