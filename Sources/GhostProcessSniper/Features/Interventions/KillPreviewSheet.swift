import AppKit
import GhostProcessSniperCore
import SwiftUI

struct KillPreviewSheet: View {
    let family: ProcessFamily
    let preview: KillPreview
    let approvalExpiresAt: Date
    let confirm: (
        _ skipForce: Bool,
        _ control: KillOperationControl,
        _ eventSink: @escaping @Sendable (KillOperationEvent) -> Void
    ) async -> KillReport
    let close: () -> Void

    @State private var isKilling = false
    @State private var previewExpired = false
    @State private var report: KillReport?
    @State private var skipForce = false
    @State private var operationControl = KillOperationControl()
    @State private var liveEvents: [KillOperationEvent] = []
    @State private var liveTargetStates: [Int32: KillTargetState] = [:]
    @State private var liveTargetReasons: [Int32: String] = [:]
    @State private var stageText = "Ready for explicit confirmation"
    @State private var selectedStep: KillPreviewStep = .scope
    @State private var showsEngineDetails = false

    init(
        family: ProcessFamily,
        preview: KillPreview,
        approvalExpiresAt: Date,
        confirm: @escaping (_ skipForce: Bool, _ control: KillOperationControl,
                            _ eventSink: @escaping @Sendable (KillOperationEvent) -> Void) async -> KillReport,
        close: @escaping () -> Void
    ) {
        self.family = family
        self.preview = preview
        self.approvalExpiresAt = approvalExpiresAt
        self.confirm = confirm
        self.close = close
        // One-time seed: work that can lose data is never forced unless the
        // user turns this off. The sheet is rebuilt for every new preview.
        _skipForce = State(initialValue: preview.riskAssessment.forceNeedsConfirmation)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)

            if report == nil, !isKilling {
                Label(previewExpired
                      ? "Preview expired. Close and open a fresh preview to continue."
                      : "60-second preview. Only the identities shown here are eligible; new descendants are skipped.",
                      systemImage: previewExpired ? "clock.badge.exclamationmark" : "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(previewExpired ? Color.orange : Color.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Intervention step", selection: $selectedStep) {
                ForEach(KillPreviewStep.allCases) { step in
                    Label(step.label, systemImage: step.systemImage)
                        .tag(step)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isKilling || report != nil)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedStep {
                    case .scope:
                        scopeStrategyPanel
                    case .targets:
                        targetTable
                    case .confirm:
                        if let report {
                            resultPanel(report)
                        } else {
                            timelinePanel
                        }
                    }
                }
                .padding(16)
            }

            Divider()
            actions
                .padding(16)
                .background(RadarTheme.panel)
        }
        .frame(width: 760, height: 700)
        .task(id: approvalExpiresAt) {
            let delay = max(0, approvalExpiresAt.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            previewExpired = true
        }
        .interactiveDismissDisabled(isKilling)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title2.weight(.semibold))
                .foregroundStyle(readinessColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("Stop \(preview.displayName)")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text("\(preview.riskAssessment.kind.label) \u{00b7} \(preview.strategyRecommendation.strategy.label) \u{00b7} \(family.signature.displayName)")
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
        VStack(alignment: .leading, spacing: 14) {
            KillPlanOverview(preview: preview)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    compactEvidenceBlock(title: "Why stop it", factors: preview.whyKillEvidence, empty: "No strong reason to stop it yet.")
                    compactEvidenceBlock(title: "Why wait", factors: preview.whyWaitEvidence, empty: "Nothing suggests waiting.")
                }
            }
            DisclosureGroup("Engine details", isExpanded: $showsEngineDetails) {
                engineDetails
                    .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    private var engineDetails: some View {
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
            Toggle("Report anything that refuses to stop instead of force-stopping it", isOn: $skipForce)
                .font(.caption)
                .toggleStyle(.switch)
                .disabled(isKilling)
            if preview.riskAssessment.forceNeedsConfirmation {
                Text("On by default for a \(preview.riskAssessment.kind.label.lowercased()): a forced stop can lose work.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
            if !report.respawnedPIDs.isEmpty {
                KillRiskCard(risk: KillRisk(kind: .respawn, severity: .caution, title: "It came back",
                                            detail: report.summary))
            } else if report.skipForceRequested, !report.survivorPIDs.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    KillRiskCard(risk: KillRisk(kind: .unsavedWork, severity: .caution, title: "Still running",
                                                detail: "Check it for a save prompt or unfinished work first."))
                    Button(role: .destructive) {
                        startKill(force: true)
                    } label: {
                        Label("Force Stop", systemImage: "bolt")
                    }
                    .disabled(isKilling || previewExpired || Date() > approvalExpiresAt)
                    .help("Runs the stop again and force-stops whatever is still running.")
                }
            }
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
                .disabled(isKilling)

            if let report {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.diagnosticText, forType: .string)
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
            }

            Spacer()

            if report == nil, !isKilling, selectedStep != .scope {
                Button {
                    selectedStep = selectedStep.previous
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }

            if report == nil {
                if selectedStep != .confirm {
                    Button {
                        selectedStep = selectedStep.next
                    } label: {
                        Label("Continue", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(role: .destructive) { startKill() } label: {
                        if isKilling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(confirmTitle, systemImage: "scope")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!preview.canKill || isKilling || previewExpired)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var confirmTitle: String {
        if preview.strategyRecommendation.strategy == .quitApp { return "Quit \(preview.displayName)" }
        return preview.scopePreview.scope == .singleRoot ? "Confirm Stop Process" : "Confirm Stop Family"
    }

    /// `force` re-runs a finished stop without holding back force, for
    /// survivors the user has checked.
    private func startKill(force: Bool = false) {
        guard !isKilling, report == nil || force, !previewExpired, Date() <= approvalExpiresAt else { return }
        if force { skipForce = false }
        report = nil
        isKilling = true
        Task {
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
        case .gentleDevServer, .quitApp: .green
        case .carefulShutdown: .purple
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
                Label("\(factor.title): \(factor.detail)", systemImage: KillFactorStyle.icon(for: factor.kind))
                    .font(.caption)
                    .foregroundStyle(KillFactorStyle.color(for: factor.kind))
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

}
