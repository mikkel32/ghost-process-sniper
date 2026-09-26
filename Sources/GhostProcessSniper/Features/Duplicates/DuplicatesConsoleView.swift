import GhostProcessSniperCore
import SwiftUI

struct DuplicatesConsoleView: View {
    let session: RadarConsoleSession
    @State private var selectedID: String?

    private var rows: [DuplicateClusterViewModel] {
        session.duplicateRows
    }

    private var selectedRow: DuplicateClusterViewModel? {
        if let selectedID, let row = rows.first(where: { $0.id == selectedID }) {
            return row
        }
        return rows.first
    }

    var body: some View {
        HStack(spacing: 0) {
            duplicateList
                .frame(minWidth: 440, idealWidth: 500, maxWidth: 560)

            Divider()

            DuplicateClusterDetailView(
                row: selectedRow,
                inspectFamily: inspectRelatedFamily,
                snoozeFamily: snoozeRelatedFamily,
                ignoreFamily: ignoreRelatedFamily,
                copyReport: session.copyDuplicateReport
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    private var duplicateList: some View {
        VStack(alignment: .leading, spacing: 0) {
            DuplicatesHeader(count: rows.count)

            if rows.isEmpty {
                ContentUnavailableView(
                    "No Duplicate Clusters",
                    systemImage: "doc.on.doc",
                    description: Text("Matching small tools will appear here when two or more same-user instances are live.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        DuplicateTableHeader()
                        ForEach(rows) { row in
                            Button {
                                selectedID = row.id
                            } label: {
                                DuplicateClusterRow(row: row, isSelected: selectedRow?.id == row.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    inspectRelatedFamily(row)
                                } label: {
                                    Label("Inspect Related Family", systemImage: "sidebar.right")
                                }
                                .disabled(row.cluster.relatedFamilyKeys.isEmpty)
                                Button {
                                    snoozeRelatedFamily(row)
                                } label: {
                                    Label("Snooze Related Family", systemImage: "moon")
                                }
                                .disabled(row.cluster.relatedFamilyKeys.isEmpty)
                                Button {
                                    ignoreRelatedFamily(row)
                                } label: {
                                    Label("Ignore Related Family", systemImage: "eye.slash")
                                }
                                .disabled(row.cluster.relatedFamilyKeys.isEmpty)
                                Divider()
                                Button {
                                    session.copyDuplicateReport(row)
                                } label: {
                                    Label("Copy Report", systemImage: "doc.on.clipboard")
                                }
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
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

    private func inspectRelatedFamily(_ row: DuplicateClusterViewModel) {
        guard let familyKey = row.cluster.relatedFamilyKeys.first else {
            return
        }
        session.focus(.family(familyKey))
    }

    private func snoozeRelatedFamily(_ row: DuplicateClusterViewModel) {
        guard let familyKey = row.cluster.relatedFamilyKeys.first else {
            return
        }
        Task { await session.monitor.snooze(signatureID: familyKey, minutes: 60) }
    }

    private func ignoreRelatedFamily(_ row: DuplicateClusterViewModel) {
        guard let familyKey = row.cluster.relatedFamilyKeys.first else {
            return
        }
        Task { await session.monitor.ignore(signatureID: familyKey) }
    }
}

private struct DuplicatesHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(count > 0 ? .orange : .secondary)
                .frame(width: 38, height: 38)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("CLUSTER ANALYSIS")
                    .font(.system(size: 8, weight: .black))
                    .tracking(1.05)
                    .foregroundStyle(.orange)
                HStack(spacing: 8) {
                    Text("Duplicate Radar")
                        .font(.title3.weight(.semibold))
                    InfoTip(tip: RadarTip(
                        title: "Duplicate Radar",
                        message: "Catches death by a thousand cuts: many small copies of the same tool (language servers, watchers, helpers) that each sit below the heavy-process thresholds but add up. Clusters need two or more live same-user instances to appear.",
                        shortcut: "⌘3"
                    ))
                }
                Text("Small repeated dev tools captured from the normal cheap scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(count)")
                .font(.headline.monospacedDigit().weight(.semibold))
                .foregroundStyle(count > 0 ? .orange : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.1), in: Capsule())
        }
        .padding(12)
        .radarSurface(tint: .orange, cornerRadius: 14)
        .padding(14)
    }
}

private struct DuplicateTableHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Count")
                .frame(width: 48, alignment: .trailing)
            Text("Memory")
                .frame(width: 70, alignment: .trailing)
            Text("CPU")
                .frame(width: 48, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct DuplicateClusterRow: View {
    let row: DuplicateClusterViewModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(row.kindText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(row.reasonText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.countText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 48, alignment: .trailing)
            Text(row.memoryText)
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Text(row.cpuText)
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .contentShape(Rectangle())
        .help(row.subtitle)
    }
}

private struct DuplicateClusterDetailView: View {
    let row: DuplicateClusterViewModel?
    let inspectFamily: (DuplicateClusterViewModel) -> Void
    let snoozeFamily: (DuplicateClusterViewModel) -> Void
    let ignoreFamily: (DuplicateClusterViewModel) -> Void
    let copyReport: (DuplicateClusterViewModel) -> Void

    var body: some View {
        if let row {
            let detail = DuplicateClusterDetailModel(cluster: row.cluster)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailHeader(row: row, detail: detail)
                    metricBand(row: row)
                    hintSection(title: "Representative Commands", image: "terminal", values: detail.commandHints)
                    hintSection(title: "Executable Paths", image: "folder", values: detail.pathHints)
                    hintSection(title: "Grouped PIDs", image: "number", values: detail.pidGroups)
                    actionSection(row: row)
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView(
                "No Duplicate Selected",
                systemImage: "doc.on.doc",
                description: Text("Duplicate clusters are quiet until two or more matching same-user processes appear.")
            )
        }
    }

    private func detailHeader(row: DuplicateClusterViewModel, detail: DuplicateClusterDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(row.reasonText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text(detail.keyText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("Captured because the normal radar saw \(detail.captureReason.lowercased()) below individual heavy-process thresholds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metricBand(row: DuplicateClusterViewModel) -> some View {
        HStack(spacing: 10) {
            CompactRadarChip(title: "Instances", value: row.countText, systemImage: "doc.on.doc", level: .watch)
            CompactRadarChip(title: "Roots", value: row.rootCountText, systemImage: "point.3.connected.trianglepath.dotted")
            CompactRadarChip(title: "Memory", value: row.memoryText, systemImage: "memorychip", level: .watch)
            CompactRadarChip(title: "CPU", value: row.cpuText, systemImage: "cpu")
            CompactRadarChip(title: "Kind", value: row.kindText, systemImage: "tag")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .radarSurface(tint: .orange, cornerRadius: 14)
    }

    private func hintSection(title: String, image: String, values: [String]) -> some View {
        CompactRadarSection(
            title: title,
            subtitle: values.isEmpty ? "none" : "\(values.count)",
            systemImage: image,
            accent: .orange
        ) {
            if values.isEmpty {
                Text("No cached hint from the cheap scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Label(value, systemImage: image)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func actionSection(row: DuplicateClusterViewModel) -> some View {
        let hasRelatedFamily = !row.cluster.relatedFamilyKeys.isEmpty
        return CompactRadarSection(title: "Safe Actions", subtitle: "advisory", systemImage: "checkmark.shield", accent: .orange) {
            HStack(spacing: 8) {
                Button {
                    inspectFamily(row)
                } label: {
                    Label("Inspect Related", systemImage: "sidebar.right")
                }
                .disabled(!hasRelatedFamily)

                Button {
                    snoozeFamily(row)
                } label: {
                    Label("Snooze", systemImage: "moon")
                }
                .disabled(!hasRelatedFamily)

                Button {
                    ignoreFamily(row)
                } label: {
                    Label("Ignore", systemImage: "eye.slash")
                }
                .disabled(!hasRelatedFamily)

                Spacer()

                Button {
                    copyReport(row)
                } label: {
                    Label("Copy Report", systemImage: "doc.on.clipboard")
                }
            }
            .controlSize(.small)
        }
    }
}
