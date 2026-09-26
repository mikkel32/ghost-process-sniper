import GhostProcessSniperCore
import SwiftUI

/// The selected cluster, led by what to do about it: the plan's one-line
/// verdict and the button that stops the extras.
struct DuplicateClusterDetailView: View {
    let row: DuplicateClusterViewModel?
    let plan: DuplicateCullPlan?
    let session: RadarConsoleSession
    let stopExtras: (DuplicateClusterViewModel) -> Void

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DuplicatePlanHero(row: row, plan: plan, session: session, stopExtras: stopExtras)
                    metricBand(row: row)
                    DuplicateCopiesSection(plan: plan, session: session)
                    hintSection(title: "Representative Commands", image: "terminal", values: row.cluster.commandHints)
                    hintSection(title: "Executable Paths", image: "folder", values: row.cluster.pathHints)
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView(
                "Select a Cluster",
                systemImage: "doc.on.doc",
                description: Text("Pick a row to see which copies are in use and which can go.")
            )
        }
    }

    private func metricBand(row: DuplicateClusterViewModel) -> some View {
        HStack(spacing: 10) {
            CompactRadarChip(title: "Copies", value: row.countText, systemImage: "doc.on.doc", level: .watch)
            CompactRadarChip(title: "Roots", value: row.rootCountText, systemImage: "point.3.connected.trianglepath.dotted")
            CompactRadarChip(title: "Memory", value: row.memoryText, systemImage: "memorychip", level: .watch)
            CompactRadarChip(title: "CPU", value: row.cpuText, systemImage: "cpu")
            CompactRadarChip(title: "Frees", value: plan?.reclaimText ?? "\u{2014}", systemImage: "arrow.down.circle")
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
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct DuplicatePlanHero: View {
    let row: DuplicateClusterViewModel
    let plan: DuplicateCullPlan?
    let session: RadarConsoleSession
    let stopExtras: (DuplicateClusterViewModel) -> Void

    var body: some View {
        let stopCount = plan?.stopCount ?? 0
        let hasRelatedFamily = !row.cluster.relatedFamilyKeys.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(row.kindText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(row.reasonText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Text(plan?.summary ?? "Checking which copies are in use\u{2026}")
                .font(.body.weight(.medium))
                .foregroundStyle(stopCount > 0 ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    stopExtras(row)
                } label: {
                    Label(DuplicateCullLabels.stopTitle(stopCount), systemImage: "stop.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(stopCount == 0)
                .help(stopCount > 0
                      ? "Check each copy in its own stop preview, then stop the ones that pass"
                      : plan?.summary ?? "")

                Button("Show Related", systemImage: "sidebar.right") {
                    session.inspectRelatedFamily(of: row)
                }
                .disabled(!hasRelatedFamily)

                Menu {
                    FamilySnoozeMenu { minutes in session.snoozeRelatedFamilies(of: row, minutes: minutes) }
                } label: {
                    Label("Snooze", systemImage: "moon")
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(!hasRelatedFamily)

                Button("Ignore", systemImage: "eye.slash") {
                    session.ignoreRelatedFamilies(of: row)
                }
                .disabled(!hasRelatedFamily)

                Spacer()

                Button("Copy Report", systemImage: "doc.on.clipboard") {
                    session.copyDuplicateReport(row)
                }
            }
        }
        .padding(14)
        .radarSurface(tint: .orange, cornerRadius: 16, raised: true)
    }
}

/// Every live copy with its Keep or Stop verdict and the reason for it.
private struct DuplicateCopiesSection: View {
    let plan: DuplicateCullPlan?
    let session: RadarConsoleSession

    var body: some View {
        CompactRadarSection(
            title: "Copies",
            subtitle: plan.map { "\($0.stopCount) to stop \u{00b7} \($0.keepCount) to keep" },
            systemImage: "square.stack.3d.up",
            tip: RadarTip(
                title: "Keep or Stop",
                message: "A copy is stopped only when it is yours, idle, and orphaned: the app or terminal that started it is gone. Copies that are busy, serving a port, run by launchd, or used by a running app are kept. Right-click any copy to stop just that one."
            ),
            accent: .orange
        ) {
            if let plan {
                if plan.decisions.isEmpty {
                    Text("Every copy has already exited.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(plan.decisions) { decision in
                            DuplicateCopyRow(
                                decision: decision,
                                showsDivider: decision.id != plan.decisions.last?.id,
                                session: session
                            )
                        }
                    }
                }
            } else {
                Text("Checking which copies are in use\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DuplicateCopyRow: View {
    let decision: DuplicateCullPlan.Decision
    let showsDivider: Bool
    let session: RadarConsoleSession

    private var isStop: Bool { decision.verdict == .stop }

    var body: some View {
        HStack(spacing: 10) {
            Text(isStop ? "Stop" : "Keep")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isStop ? Color.orange : Color.green)
                .frame(width: 42)
                .padding(.vertical, 2)
                .background((isStop ? Color.orange : Color.green).opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(decision.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("PID \(String(decision.pid))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(decision.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Text(decision.memoryText)
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            Text(decision.cpuText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
            }
        }
        .contentShape(Rectangle())
        .help(decision.reason)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isStop ? "Stop" : "Keep"), \(decision.name), PID \(String(decision.pid)), \(decision.reason)")
        .contextMenu {
            Button("Stop This Copy\u{2026}", systemImage: "stop.circle", role: .destructive) {
                session.prepareKill(processIdentity: decision.identity, name: decision.name)
            }
            .disabled(decision.rule == .notYours)
            Button("Copy PID", systemImage: "number") {
                session.copyPIDs([decision.pid])
            }
        }
    }
}
