import AppKit
import GhostProcessSniperCore
import SwiftUI

struct KillPreviewSheet: View {
    let family: ProcessFamily
    let preview: KillPreview
    let confirm: (
        _ skipForce: Bool,
        _ control: KillOperationControl,
        _ eventSink: @escaping @Sendable (KillOperationEvent) -> Void
    ) async -> KillReport
    let close: () -> Void

    @State private var isKilling = false
    @State private var report: KillReport?
    @State private var skipForce = false
    @State private var operationControl = KillOperationControl()
    @State private var liveEvents: [KillOperationEvent] = []
    @State private var liveTargetStates: [Int32: KillTargetState] = [:]
    @State private var liveTargetReasons: [Int32: String] = [:]
    @State private var stageText = "Ready for explicit confirmation"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            scopeStrategyPanel
            targetTable
            if let report {
                resultPanel(report)
            } else {
                timelinePanel
            }
            actions
        }
        .padding(16)
        .frame(width: 720)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title2.weight(.semibold))
                .foregroundStyle(readinessColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("Intervention Console")
                    .font(.title2.weight(.semibold))
                Text("\(preview.displayName) - \(family.signature.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(preview.readiness.label)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(readinessColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(readinessColor.opacity(0.12), in: Capsule())
                Text(preview.usedCheapSnapshot ? "arena kill graph" : "full preflight")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(preview.strategyRecommendation.strategy.label) - \(preview.scopePreview.scope.label)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var scopeStrategyPanel: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                compactInfoBlock(
                    title: "Scope",
                    icon: "person.crop.circle.badge.checkmark",
                    accent: .blue,
                    primary: preview.scopePreview.scope.label,
                    secondary: preview.scopePreview.summary,
                    tags: [
                        "will signal \(preview.scopePreview.targetCount)",
                        "skip \(preview.scopePreview.lockedCount + preview.scopePreview.drift.exitedPIDs.count + preview.scopePreview.drift.recycledPIDs.count)",
                        "nearby \(preview.scopePreview.nearbyCandidates.count)"
                    ],
                    tip: RadarTip(
                        title: "Scope",
                        message: "Exactly which processes will receive signals. Locked (protected or foreign), already-exited, and recycled PIDs are skipped automatically. \"Nearby\" processes look related but are deliberately not targeted — check them in the panel below."
                    )
                )
                compactInfoBlock(
                    title: "Strategy",
                    icon: "dial.low",
                    accent: strategyColor,
                    primary: preview.strategyRecommendation.strategy.label,
                    secondary: preview.strategySimulation.summary,
                    tags: [
                        "\(Int((preview.strategyRecommendation.confidence * 100).rounded()))%",
                        "\(Int((preview.expectedGracefulSuccess * 100).rounded()))% graceful",
                        "\(Int((preview.forceProbability * 100).rounded()))% force",
                        "\(String(format: "%.2f", preview.recommendedGraceSeconds))s grace"
                    ],
                    tip: RadarTip(
                        title: "Strategy",
                        message: "How the kill escalates, tuned per process type: graceful signals first (dev servers get gentler treatment), then verification, and force only for verified survivors. The percentages are the simulated odds of each path."
                    )
                )
            }
            GridRow {
                compactInfoBlock(
                    title: "Confidence",
                    icon: "checkmark.shield",
                    accent: readinessColor,
                    primary: preview.readiness.label,
                    secondary: preview.riskSummary,
                    tags: [
                        "score \(Int(preview.decisionScore.value.rounded()))",
                        preview.watcherAvailable ? "watcher ready" : "watcher off",
                        "\(Int((preview.survivorRisk * 100).rounded()))% survivor"
                    ],
                    tip: RadarTip(
                        title: "Confidence",
                        message: "The engine's readiness verdict from a live preflight of the process tree. The Why Kill / Why Wait lists below are the actual evidence — read them before confirming. Nothing runs without your explicit confirmation."
                    )
                )
                compactInfoBlock(
                    title: "Budget",
                    icon: "speedometer",
                    accent: preview.performanceReport.didHitBudget ? .orange : .secondary,
                    primary: "\(Int(preview.performanceReport.snapshotMilliseconds.rounded())) ms preflight",
                    secondary: "\(preview.arenaStats.processCount) arena rows, \(preview.performanceReport.graphReadCount) PID reads, \(preview.performanceReport.heavyMetricReadCount) target-heavy reads. \(preview.verificationPlanText)",
                    tags: [
                        "arena \(Int(preview.arenaStats.arenaBuildMilliseconds.rounded())) ms",
                        "reuse \(preview.arenaStats.arenaReuseCount)",
                        "reclaim \(RadarFormat.bytes(preview.estimatedMemoryReclaimBytes))",
                        "converted \(preview.targetConversionCount)"
                    ],
                    tip: RadarTip(
                        title: "Budget",
                        message: "What this preview cost to compute. The kill graph is cached and reused between previews, and \"reclaim\" estimates how much memory a successful kill frees."
                    )
                )
            }
            GridRow {
                compactEvidenceBlock(title: "Why Kill", factors: preview.whyKillEvidence, empty: "No strong positive evidence yet.")
                compactEvidenceBlock(title: "Why Wait", factors: preview.whyWaitEvidence, empty: "No blocking or caution evidence found.")
            }
        }
    }

    private var targetTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Targets")
                    .font(.headline)
                InfoTip(tip: RadarTip(
                    title: "Targets",
                    message: "Every process in the tree with its live state. During the kill this table updates in real time: terminated, force-killed, survived, or exited on its own before any signal arrived."
                ))
                Spacer()
                if !preview.targetDiff.summary.isEmpty {
                    Text(preview.targetDiff.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("root PID \(preview.rootPID)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    let rows = displayedRows
                    if rows.isEmpty {
                        ContentUnavailableView("No Live Targets", systemImage: "scope")
                            .frame(minHeight: 120)
                    } else {
                        ForEach(rows) { target in
                            KillTargetRow(target: target)
                            if target.id != rows.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !preview.scopePreview.nearbyCandidates.isEmpty {
                nearbyPanel
            }
        }
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(preview.strategyProfile.phases) { phase in
                    Label(phase.signalName, systemImage: phase.isForce ? "bolt" : "\(phase.order + 1).circle")
                    if phase.id != preview.strategyProfile.phases.last?.id {
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                if preview.strategyProfile.phases.isEmpty {
                    Label("Inspect only", systemImage: "magnifyingglass")
                }
                Spacer()
            }
            Toggle("Skip force escalation and report survivors", isOn: $skipForce)
                .font(.caption)
                .toggleStyle(.switch)
                .disabled(isKilling)
            if isKilling && !skipForce {
                Button {
                    skipForce = true
                    stageText = "Skip-force requested. The intervention will verify and report survivors."
                    Task {
                        await operationControl.requestSkipForce()
                    }
                } label: {
                    Label("Skip Force Now", systemImage: "hand.raised")
                }
                .controlSize(.small)
            }
            if isKilling {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            Text(stageText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: stageText)
            if !liveEvents.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(liveEvents.suffix(6)) { event in
                        HStack(spacing: 6) {
                            Text(event.kind.rawValue)
                                .foregroundStyle(.secondary)
                                .frame(width: 82, alignment: .leading)
                            if let pid = event.pid {
                                Text("PID \(pid)")
                                    .frame(width: 62, alignment: .leading)
                            }
                            Text(event.message)
                                .lineLimit(1)
                        }
                    }
                }
                .font(.caption2.monospacedDigit())
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func resultPanel(_ report: KillReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(report.summary, systemImage: report.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(report.succeeded ? Color.green : Color.orange)
                    .lineLimit(2)
                Spacer()
                Text("\(Int(report.timeline.totalMilliseconds.rounded())) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            FlowTags(
                title: "Result",
                items: [
                    report.strategyUsed.label,
                    report.scopeUsed.label,
                    "term \(report.gracefulPIDs.count)",
                    "force \(report.forcedPIDs.count)",
                    "locked \(report.deniedPIDs.count)",
                    "survivors \(report.survivorPIDs.count)",
                    "drift \(report.finalGraphDelta.summary)",
                    "hints \(report.reactorReport.watcherHints.count)",
                    "verify \(report.verificationSnapshotCount)",
                    "saved \(String(format: "%.2f", report.reactorReport.earlyExitSavingsSeconds))s",
                    RadarFormat.bytes(report.realizedMemoryReclaimBytes)
                ]
            )
            if !report.verificationPasses.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(report.verificationPasses.prefix(4)) { pass in
                        Text("\(pass.stage): live \(pass.livePIDs.count), recycled \(pass.recycledPIDs.count), exited \(pass.exitedPIDs.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var actions: some View {
        HStack {
            Button(report == nil ? "Cancel" : "Done", action: close)
                .keyboardShortcut(.cancelAction)

            if let report {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.diagnosticText, forType: .string)
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
            }

            Spacer()

            Button(role: .destructive) {
                Task {
                    isKilling = true
                    liveEvents = []
                    liveTargetStates = [:]
                    liveTargetReasons = [:]
                    operationControl = KillOperationControl()
                    let firstSignal = preview.strategyProfile.phases.first?.signalName ?? "signal"
                    stageText = skipForce ? "Sending \(firstSignal) and verifying without force..." : "Sending \(firstSignal), then verifying before force..."
                    let control = operationControl
                    let eventSink: @Sendable (KillOperationEvent) -> Void = { event in
                        Task { @MainActor in
                            liveEvents.append(event)
                            if let pid = event.pid, let state = event.targetState {
                                liveTargetStates[pid] = state
                                liveTargetReasons[pid] = event.message
                            }
                            stageText = event.message
                        }
                    }
                    let result = await confirm(skipForce, control, eventSink)
                    await MainActor.run {
                        report = result
                        stageText = result.summary
                        isKilling = false
                    }
                }
            } label: {
                if isKilling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Confirm Kill Tree", systemImage: "scope")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!preview.canKill || isKilling || report != nil)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var allRows: [KillTarget] {
        preview.targets + preview.lockedTargets + preview.staleTargets + preview.recycledTargets
    }

    private var displayedRows: [KillTarget] {
        if let report, !report.targetResults.isEmpty {
            return report.targetResults.sorted { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
                return lhs.pid > rhs.pid
            }
        }
        return allRows.map { target in
            guard let state = liveTargetStates[target.pid] else {
                return target
            }
            return target.updating(state: state, reason: liveTargetReasons[target.pid] ?? target.reason)
        }
    }

    private var readinessColor: Color {
        switch preview.readiness {
        case .ready: .green
        case .caution: .orange
        case .locked: .red
        }
    }

    private var strategyColor: Color {
        switch preview.strategyRecommendation.strategy {
        case .standard: .blue
        case .gentleDevServer: .green
        case .stubbornRunaway: .red
        case .inspectOnly: .orange
        }
    }

    private var nearbyCandidates: [KillCollateralCandidate] {
        Swift.Array(preview.scopePreview.nearbyCandidates.prefix(4))
    }

    private func compactEvidenceBlock(title: String, factors: [KillDecisionFactor], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "list.bullet.clipboard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(factors.prefix(4)) { factor in
                Label("\(factor.title): \(factor.detail)", systemImage: icon(for: factor.kind))
                    .font(.caption)
                    .foregroundStyle(color(for: factor.kind))
                    .lineLimit(1)
            }
            if factors.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var nearbyPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Nearby but not targeted", systemImage: "person.2.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(nearbyCandidates, id: \.id) { (candidate: KillCollateralCandidate) in
                HStack {
                    Text(candidate.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text("PID \(candidate.identity.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(candidate.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func compactInfoBlock(
        title: String,
        icon: String,
        accent: Color,
        primary: String,
        secondary: String,
        tags: [String],
        tip: RadarTip? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                if let tip {
                    InfoTip(tip: tip)
                }
            }
            Text(primary)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(secondary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 5) {
                ForEach(tags.prefix(4), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.background.opacity(0.45), in: Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func signalLabel(_ signal: Int32) -> String {
        switch signal {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        default: "SIG\(signal)"
        }
    }
}

private struct KillTargetRow: View {
    let target: KillTarget

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(target.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if target.isRoot {
                        Text("root")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(target.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("PID \(target.pid)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            Text(target.state.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var icon: String {
        switch target.state {
        case .ready: "checkmark.circle"
        case .locked: "lock"
        case .stale: "clock.badge.xmark"
        case .recycled: "arrow.triangle.2.circlepath"
        case .terminated: "checkmark.seal"
        case .forceKilled: "bolt"
        case .survived: "exclamationmark.triangle"
        case .exitedBeforeSignal: "figure.run"
        case .failed: "xmark.octagon"
        }
    }

    private var color: Color {
        switch target.state {
        case .ready, .terminated: .green
        case .locked, .stale, .recycled: .orange
        case .forceKilled: .red
        case .exitedBeforeSignal: .secondary
        case .survived, .failed: .red
        }
    }
}

private func icon(for evidence: KillDecisionEvidenceKind) -> String {
    switch evidence {
    case .positive: "checkmark.seal"
    case .caution: "exclamationmark.triangle"
    case .blocking: "xmark.octagon"
    case .info: "info.circle"
    }
}

private func icon(for factor: KillDecisionFactorKind) -> String {
    switch factor {
    case .whyKill: "checkmark.seal"
    case .whyWait: "exclamationmark.triangle"
    case .blocking: "xmark.octagon"
    }
}

private func color(for evidence: KillDecisionEvidenceKind) -> Color {
    switch evidence {
    case .positive: .green
    case .caution: .orange
    case .blocking: .red
    case .info: .secondary
    }
}

private func color(for factor: KillDecisionFactorKind) -> Color {
    switch factor {
    case .whyKill: .green
    case .whyWait: .orange
    case .blocking: .red
    }
}
