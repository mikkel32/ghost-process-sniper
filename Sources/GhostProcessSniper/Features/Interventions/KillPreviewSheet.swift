import AppKit
import GhostProcessSniperCore
import SwiftUI

/// The stop sheet: one scrolling page from plan to result. Confirm needs
/// Command-Return, so Return alone never stops anything.
struct KillPreviewSheet: View {
    let pending: PendingKill
    let session: RadarConsoleSession
    let close: () -> Void

    @Environment(\.appearsActive) private var appearsActive

    @State private var isKilling = false
    @State private var report: KillReport?
    @State private var reportedAt: Date?
    @State private var canForceSurvivors = false
    @State private var skipForce: Bool
    @State private var launchdStop: KillLaunchdStop
    @State private var operationControl = KillOperationControl()
    @State private var waitingStopped = false
    @State private var progress: KillLiveProgress
    /// The rows a force follow-up starts from: the held stop's outcome, not
    /// the preview's "Ready" targets. Nil for the stop itself.
    @State private var followUpRows: [KillTarget]?
    @State private var showsTargets: Bool
    @State private var showsEngineDetails = false
    /// Briefly true after a refresh changed the plan, so a click aimed at
    /// the old plan cannot confirm the new one.
    @State private var confirmHeld = false
    @State private var offersUpdate = false

    init(pending: PendingKill, session: RadarConsoleSession, close: @escaping () -> Void) {
        self.pending = pending
        self.session = session
        self.close = close
        let preview = pending.preview
        // One-time seeds: work that can lose data is never forced unless the
        // user turns this off, and a KeepAlive job is stopped as a service.
        _skipForce = State(initialValue: preview.riskAssessment.forceNeedsConfirmation)
        _launchdStop = State(initialValue: preview.offersLaunchdStop ? .untilLogin : .none)
        _progress = State(initialValue: KillLiveProgress(preview: preview))
        _showsTargets = State(initialValue: !preview.lockedTargets.isEmpty
            || !preview.scopePreview.nearbyCandidates.isEmpty || preview.targets.count <= 6)
    }

    private var preview: KillPreview { pending.preview }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let report {
                        resultPanel(report)
                    } else if isKilling {
                        KillProgressPanel(progress: progress, targets: followUpRows ?? preview.targets,
                                          skippedCount: followUpRows == nil ? skippedCount : 0, forceHeld: skipForce,
                                          waitingStopped: waitingStopped, holdForce: holdForce, stopWaiting: stopWaiting)
                    } else {
                        planPage
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
                .padding(16)
                .background(RadarTheme.panel)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .interactiveDismissDisabled(isKilling)
        .task(id: pending.expiresAt) { await refreshWhenExpired() }
        .task(id: pending.preparedAt) { await holdConfirmAfterChange() }
        .task(id: reportedAt) { await closeForceWindow() }
        .onChange(of: appearsActive) { _, active in
            // Back after a while: the processes may have moved on.
            if active, report == nil, !isKilling, Date().timeIntervalSince(pending.preparedAt) > 20 {
                offersUpdate = true
            }
        }
        .onChange(of: preview.riskAssessment.forceNeedsConfirmation) { _, needs in
            if needs { skipForce = true }
        }
        .onChange(of: preview.offersLaunchdStop) { _, offers in
            launchdStop = offers ? .untilLogin : .none
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title2.weight(.semibold))
                .foregroundStyle(KillReadinessStyle.color(preview.readiness))
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Stop \(preview.displayName)")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(preview.readiness.label)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(KillReadinessStyle.color(preview.readiness))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(KillReadinessStyle.color(preview.readiness).opacity(0.12), in: Capsule())
        }
    }

    private var subtitle: String {
        var parts = [preview.riskAssessment.kind.label, preview.strategyRecommendation.strategy.label]
        let family = pending.family.signature.displayName
        if family != preview.displayName { parts.append(family) }
        return parts.joined(separator: " \u{00b7} ")
    }

    @ViewBuilder
    private var planPage: some View {
        if let change = pending.change {
            Label(change.text, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        if offersUpdate || session.isRefreshingPreview {
            HStack(spacing: 10) {
                Label(session.isRefreshingPreview ? "Updating the preview\u{2026}" : "The processes may have changed while you were away.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Update Preview") {
                    offersUpdate = false
                    session.refreshPendingKill()
                }
                .disabled(session.isRefreshingPreview)
            }
        }

        KillPlanOverview(preview: preview, forceHeld: skipForce, isPreparing: session.isPreparingIntervention) { alternative in
            session.prepareKill(pending.family, plan: alternative.plan)
        }

        if preview.offersLaunchdStop, let job = preview.launchdJob {
            KillLaunchdStopOptions(job: job, stop: $launchdStop)
        }

        KillEvidenceColumns(preview: preview)

        DisclosureGroup(isExpanded: $showsTargets) {
            targets
                .padding(.top, 6)
        } label: {
            Text("Targets (\(preview.targets.count))")
                .font(.headline)
        }

        DisclosureGroup("Engine details", isExpanded: $showsEngineDetails) {
            KillEngineDetails(preview: preview)
                .padding(.top, 8)
        }
        .font(.callout)
    }

    private var targets: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !preview.targetDiff.summary.isEmpty {
                Text(preview.targetDiff.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let rows = planRows
            if rows.isEmpty {
                ContentUnavailableView("No Live Targets", systemImage: "scope")
                    .frame(minHeight: 100)
            } else {
                KillTargetRows(rows: rows)
            }
            if !preview.scopePreview.nearbyCandidates.isEmpty {
                KillNearbyPanel(candidates: preview.scopePreview.nearbyCandidates)
            }
        }
    }

    /// Everything the preview sorted, one row per process.
    private var planRows: [KillTarget] {
        var seen = Set<ProcessIdentity>()
        let all = preview.targets + preview.lockedTargets + preview.staleTargets + preview.recycledTargets + preview.exitedTargets
        return all.filter { seen.insert($0.identity).inserted }
    }

    private var skippedCount: Int {
        preview.lockedTargets.count + preview.staleTargets.count + preview.recycledTargets.count + preview.exitedTargets.count
    }

    private func resultPanel(_ report: KillReport) -> some View {
        let restarter = preview.alternatives.first { $0.kind == .stopSupervisor }
        return KillResultPanel(
            report: report,
            canForceSurvivors: canForceSurvivors,
            isBusy: isKilling || session.isPreparingIntervention,
            forceSurvivors: { forceSurvivors(of: report) },
            stopRestarter: restarter.map { alternative in
                (title: "\(alternative.title)\u{2026}", action: { session.prepareKill(pending.family, plan: alternative.plan) })
            },
            canStopPortHolder: { session.family(containingPID: $0) != nil },
            stopPortHolder: { pid in
                session.dismissStopSheetForFollowUp()
                session.prepareKill(portHolder: pid)
            }
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let report {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.diagnosticText, forType: .string)
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isKilling)
            } else {
                if preview.strategyProfile.phases.contains(where: \.isForce) {
                    Toggle("Never force-stop", isOn: $skipForce)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(isKilling)
                        .help(preview.riskAssessment.forceNeedsConfirmation
                              ? "On by default for a \(preview.riskAssessment.kind.label.lowercased()): a forced stop can lose work. Anything that refuses to stop is reported instead."
                              : "Report anything that refuses to stop instead of force-stopping it.")
                }
                Spacer()
                if let caption = footerCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isKilling)
                if !preview.strategyProfile.phases.isEmpty {
                    Button(role: .destructive, action: startKill) {
                        if isKilling {
                            Text("Stopping\u{2026}")
                        } else {
                            Label(confirmTitle, systemImage: "scope")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Command-Return")
                    .disabled(!preview.canKill || isKilling || confirmHeld || session.isRefreshingPreview)
                }
            }
        }
    }

    /// Why Confirm is disabled or missing: the block itself, not the
    /// strategy's rationale, which may still read "Standard stop".
    private var footerCaption: String? {
        if let blocked = preview.confirmBlockedReason { return blocked }
        guard preview.strategyProfile.phases.isEmpty else { return nil }
        return preview.strategyRecommendation.reasons.first ?? preview.riskSummary
    }

    private var confirmTitle: String {
        if launchdStop != .none { return "Stop the Service" }
        if preview.strategyRecommendation.strategy == .quitApp { return "Quit \(preview.displayName)" }
        if preview.scopePreview.scope == .singleRoot || preview.targets.count == 1 { return "Stop \(preview.displayName)" }
        return "Stop \(preview.targets.count) Processes"
    }

    private func startKill() {
        guard !isKilling, report == nil, preview.canKill else { return }
        let control = KillOperationControl()
        operationControl = control
        let pending = pending
        let hold = skipForce
        let launchd = launchdStop
        let session = session
        run { sink in
            await session.confirmKill(pending, skipForce: hold, launchdStop: launchd, control: control, eventSink: sink)
        }
    }

    /// SIGKILL now, to the survivors of the held stop only.
    private func forceSurvivors(of finished: KillReport) {
        guard !isKilling, canForceSurvivors else { return }
        let pending = pending
        let session = session
        run(from: KillOutcomeRows.make(report: finished)) { sink in
            await session.forceSurvivors(pending, report: finished, eventSink: sink) ?? finished
        }
    }

    /// Runs a stop and feeds its events to the display in the order they
    /// were sent; the report is shown only after the last event.
    private func run(
        from rows: [KillTarget]? = nil,
        _ stop: @escaping @MainActor @Sendable (@escaping @Sendable (KillOperationEvent) -> Void) async -> KillReport
    ) {
        isKilling = true
        report = nil
        waitingStopped = false
        progress = KillLiveProgress(preview: preview)
        followUpRows = rows
        Task {
            let (events, continuation) = AsyncStream.makeStream(of: KillOperationEvent.self)
            let consumer = Task {
                for await event in events {
                    progress.apply(event)
                }
            }
            let result = await stop { event in
                _ = continuation.yield(event)
            }
            continuation.finish()
            await consumer.value
            report = result
            reportedAt = Date()
            isKilling = false
            AccessibilityNotification.Announcement(result.narrative.headline).post()
        }
    }

    private func holdForce() {
        skipForce = true
        let control = operationControl
        Task { await control.holdForce() }
    }

    private func stopWaiting() {
        waitingStopped = true
        skipForce = true
        let control = operationControl
        Task { await control.stopWaiting() }
    }

    /// No dead end at the 60 s approval: the preview is taken again in place.
    private func refreshWhenExpired() async {
        let delay = pending.expiresAt.timeIntervalSinceNow
        if delay > 0 {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
        guard report == nil, !isKilling else { return }
        session.refreshPendingKill()
    }

    private func holdConfirmAfterChange() async {
        offersUpdate = false
        guard pending.change != nil else {
            confirmHeld = false
            return
        }
        confirmHeld = true
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
        confirmHeld = false
    }

    /// Survivors can be force-stopped for a minute after the report; after
    /// that, what is still running deserves a fresh look first.
    private func closeForceWindow() async {
        guard let reportedAt else { return }
        canForceSurvivors = true
        let delay = reportedAt.addingTimeInterval(60).timeIntervalSinceNow
        do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
        canForceSurvivors = false
    }
}
