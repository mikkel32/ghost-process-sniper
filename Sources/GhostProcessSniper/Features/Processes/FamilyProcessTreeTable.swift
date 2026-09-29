import GhostProcessSniperCore
import SwiftUI

/// Every member of the family as an outline, with a per-process menu so a
/// single helper can be stopped without touching the rest of the tree.
struct FamilyProcessTreeTable: View {
    let rows: [FamilyProcessTreeRow]
    let actions: FamilyPageActions

    @State private var selection: Set<ProcessIdentity> = []

    var body: some View {
        Table(rows, children: \.children, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .lineLimit(1)
                    if row.isRoot {
                        FamilyMemberTag(text: "root")
                    }
                    if row.isGrowthCulprit {
                        FamilyMemberTag(text: "leaking", tint: .orange)
                            .help("Most of this family's memory growth comes from this process")
                    }
                }
                .help(row.commandLine)
            }
            .width(min: 160, ideal: 260)

            TableColumn("PID") { row in
                Text(String(row.pid))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64)
            .alignment(.trailing)

            TableColumn("Memory") { row in
                Text(row.memoryText)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            .alignment(.trailing)

            // Always present and empty for most rows, so the column never
            // appears or vanishes as the family's growth comes and goes.
            TableColumn("Growth") { row in
                Text(row.growthText ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            .width(96)
            .alignment(.trailing)

            TableColumn("CPU") { row in
                Text(row.cpuText)
                    .monospacedDigit()
            }
            .width(min: 44, ideal: 56)
            .alignment(.trailing)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: ProcessIdentity.self) { identities in
            menu(for: identities)
        }
    }

    @ViewBuilder
    private func menu(for identities: Set<ProcessIdentity>) -> some View {
        let selected = identities.compactMap { identity in rows.lazy.compactMap { $0.find(identity) }.first }
        if selected.count == 1, let row = selected.first {
            Button("Stop This Process\u{2026}", systemImage: "stop.circle", role: .destructive) {
                actions.stopProcess(row.id)
            }
            .disabled(!row.isStoppable)
            Divider()
            Button("Copy PID", systemImage: "number") { actions.copyPIDs([row.pid]) }
            Button("Copy Command Line", systemImage: "terminal") {
                actions.copy(row.commandLine, "Copied command line")
            }
            .disabled(row.commandLine.isEmpty)
            Button("Reveal in Finder", systemImage: "folder") { actions.reveal(row.executablePath) }
                .disabled(row.executablePath.isEmpty)
        } else if !selected.isEmpty {
            Button("Copy \(selected.count) PIDs", systemImage: "number") {
                actions.copyPIDs(selected.map(\.pid).sorted())
            }
        }
    }
}

/// A small capsule beside a process name: "root", "leaking".
struct FamilyMemberTag: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.map { AnyShapeStyle($0.opacity(0.15)) } ?? AnyShapeStyle(.quaternary), in: Capsule())
    }
}

private extension FamilyProcessTreeRow {
    func find(_ identity: ProcessIdentity) -> FamilyProcessTreeRow? {
        if id == identity { return self }
        return children?.lazy.compactMap { $0.find(identity) }.first
    }
}
