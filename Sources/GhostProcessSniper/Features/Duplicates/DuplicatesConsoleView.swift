import Darwin
import GhostProcessSniperCore
import SwiftUI

/// Duplicate clusters in a table and, for the selected one, a plan that
/// keeps the copies in use and offers to stop the orphaned extras.
struct DuplicatesConsoleView: View {
    let session: RadarConsoleSession
    @State private var selectedID: DuplicateClusterViewModel.ID?
    @State private var plans: [String: DuplicateCullPlan] = [:]

    private var rows: [DuplicateClusterViewModel] {
        session.duplicateRows
    }

    private var selectedRow: DuplicateClusterViewModel? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Duplicate Clusters",
                    systemImage: "doc.on.doc",
                    description: Text("Matching small tools appear here when two or more of your copies run at once.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    DuplicateClusterTable(
                        rows: rows,
                        plans: plans,
                        selection: $selectedID,
                        session: session,
                        stopExtras: stopExtras
                    )
                    .frame(minWidth: 360, idealWidth: 440)

                    DuplicateClusterDetailView(
                        row: selectedRow,
                        plan: selectedID.flatMap { plans[$0] },
                        session: session,
                        stopExtras: stopExtras
                    )
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Duplicates")
        .background {
            LinearGradient(
                colors: [Color.orange.opacity(0.055), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
        .onAppear(perform: stabilizeSelection)
        .onChange(of: rows.map(\.id)) { _, _ in
            stabilizeSelection()
        }
        .task(id: PlanInput(sampleRevision: session.monitor.sampleRevision, rows: rows)) {
            await updatePlans()
        }
    }

    private var header: some View {
        RadarPageHeader(
            eyebrow: "Cluster Analysis",
            title: "Duplicates",
            subtitle: headerSubtitle,
            systemImage: "doc.on.doc",
            accent: .orange
        ) {
            InfoTip(tip: RadarTip(
                title: "Duplicates",
                message: "Catches death by a thousand cuts: many small copies of the same tool (language servers, watchers, helpers) that each sit below the heavy-process thresholds but add up. Stop the extras keeps every copy that is in use and stops only idle copies whose app is gone, each through its own stop preview.",
                shortcut: "\u{2318}3"
            ))
        }
        .padding([.top, .horizontal], 20)
        .padding(.bottom, 14)
    }

    private var headerSubtitle: String {
        guard !rows.isEmpty else { return "No repeated tools right now." }
        let extras = rows.reduce(0) { $0 + (plans[$1.id]?.stopCount ?? 0) }
        let clusters = "\(rows.count) \(rows.count == 1 ? "cluster" : "clusters")"
        return extras > 0 ? "\(clusters) \u{00b7} \(extras) orphaned \(extras == 1 ? "copy" : "copies") can go" : clusters
    }

    private func stabilizeSelection() {
        guard !rows.isEmpty else {
            selectedID = nil
            return
        }
        if selectedID == nil || rows.contains(where: { $0.id == selectedID }) == false {
            selectedID = rows.first?.id
        }
    }

    /// One run at a time: a second one would preview and stop the same
    /// copies while the first still waits out their grace periods.
    private func stopExtras(_ row: DuplicateClusterViewModel) {
        guard session.cullRun == nil, let plan = plans[row.id], plan.stopCount > 0 else { return }
        session.cullRun = DuplicateCullRun(plan: plan)
    }

    private func updatePlans() async {
        let clusters = rows.map(\.cluster)
        guard !clusters.isEmpty else {
            plans = [:]
            return
        }
        let sample = session.monitor.sampledProcesses
        let userID = geteuid()
        // Parent and child lookups walk the whole sample; keep them off the main thread.
        let fresh = await Task.detached(priority: .userInitiated) {
            DuplicateCullPlan.plans(for: clusters, sample: sample, currentUserID: userID)
        }.value
        guard !Task.isCancelled else { return }
        plans = fresh
    }
}

/// Plans depend on the clusters and on the sample their parents are looked up in.
private struct PlanInput: Equatable {
    let sampleRevision: UInt64
    let rows: [DuplicateClusterViewModel]
}

/// Clusters in a native table: arrow keys move, Return or a double-click
/// opens the related family, and Delete previews stopping the extras.
private struct DuplicateClusterTable: View {
    let rows: [DuplicateClusterViewModel]
    let plans: [String: DuplicateCullPlan]
    @Binding var selection: DuplicateClusterViewModel.ID?
    let session: RadarConsoleSession
    let stopExtras: (DuplicateClusterViewModel) -> Void

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(row.kindText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(row.subtitle)
            }
            .width(min: 150, ideal: 210)

            TableColumn("Copies") { row in
                Text(row.countText)
                    .monospacedDigit()
            }
            .width(min: 44, ideal: 52)
            .alignment(.trailing)

            TableColumn("Extras") { row in
                let stopCount = plans[row.id]?.stopCount ?? 0
                Text(stopCount > 0 ? String(stopCount) : "\u{2014}")
                    .monospacedDigit()
                    .fontWeight(stopCount > 0 ? .semibold : .regular)
                    .foregroundStyle(stopCount > 0 ? Color.orange : Color.secondary)
                    .help(plans[row.id]?.summary ?? "")
            }
            .width(min: 44, ideal: 52)
            .alignment(.trailing)

            TableColumn("Memory") { row in
                Text(row.memoryText)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 72)
            .alignment(.trailing)

            TableColumn("CPU") { row in
                Text(row.cpuText)
                    .monospacedDigit()
            }
            .width(min: 44, ideal: 52)
            .alignment(.trailing)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: DuplicateClusterViewModel.ID.self) { ids in
            if let row = row(in: ids) {
                DuplicateClusterMenu(row: row, plan: plans[row.id], session: session, stopExtras: stopExtras)
            }
        } primaryAction: { ids in
            if let row = row(in: ids) {
                session.inspectRelatedFamily(of: row)
            }
        }
        .onDeleteCommand {
            if let selection, let row = row(in: [selection]) {
                stopExtras(row)
            }
        }
    }

    private func row(in ids: Set<DuplicateClusterViewModel.ID>) -> DuplicateClusterViewModel? {
        guard !ids.isEmpty else { return nil }
        return rows.first { ids.contains($0.id) }
    }
}

private struct DuplicateClusterMenu: View {
    let row: DuplicateClusterViewModel
    let plan: DuplicateCullPlan?
    let session: RadarConsoleSession
    let stopExtras: (DuplicateClusterViewModel) -> Void

    var body: some View {
        let stopCount = plan?.stopCount ?? 0
        let familyCount = row.cluster.relatedFamilyKeys.count
        Button(DuplicateCullLabels.stopTitle(stopCount), systemImage: "stop.circle", role: .destructive) {
            stopExtras(row)
        }
        .disabled(stopCount == 0)
        Divider()
        Button("Show Related Family", systemImage: "sidebar.right") {
            session.inspectRelatedFamily(of: row)
        }
        .disabled(familyCount == 0)
        Menu {
            FamilySnoozeMenu { minutes in session.snoozeRelatedFamilies(of: row, minutes: minutes) }
        } label: {
            Label(familyCount > 1 ? "Snooze \(familyCount) Families" : "Snooze", systemImage: "moon")
        }
        .disabled(familyCount == 0)
        Button(familyCount > 1 ? "Ignore \(familyCount) Families" : "Ignore Family", systemImage: "eye.slash") {
            session.ignoreRelatedFamilies(of: row)
        }
        .disabled(familyCount == 0)
        Divider()
        Button("Copy Report", systemImage: "doc.on.clipboard") {
            session.copyDuplicateReport(row)
        }
    }
}

enum DuplicateCullLabels {
    static func stopTitle(_ stopCount: Int) -> String {
        switch stopCount {
        case 0: "Nothing to Stop"
        case 1: "Stop 1 Copy\u{2026}"
        default: "Stop \(stopCount) Copies\u{2026}"
        }
    }
}

/// Snooze and Ignore cover every family the cluster spans, and say so in a toast.
extension RadarConsoleSession {
    func inspectRelatedFamily(of row: DuplicateClusterViewModel) {
        guard let familyKey = row.cluster.relatedFamilyKeys.first else { return }
        focus(.family(familyKey))
    }

    func snoozeRelatedFamilies(of row: DuplicateClusterViewModel, minutes: TimeInterval) {
        snooze(families: relatedFamilies(of: row), minutes: minutes)
    }

    func ignoreRelatedFamilies(of row: DuplicateClusterViewModel) {
        ignore(families: relatedFamilies(of: row))
    }

    private func relatedFamilies(of row: DuplicateClusterViewModel) -> [(key: String, name: String)] {
        row.cluster.relatedFamilyKeys.map { (key: $0, name: row.title) }
    }
}
