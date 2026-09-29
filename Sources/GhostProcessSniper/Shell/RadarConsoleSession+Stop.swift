import Foundation
import GhostProcessSniperCore

/// Stopping processes: previews, the in-place refresh, confirming, and the
/// follow-ups a finished stop offers.
extension RadarConsoleSession {
    /// A precision stop of one `member` is audited but not learned: how one
    /// worker stops says nothing about how the family does.
    /// - Parameter redirectedFrom: the family the user asked to stop, when
    ///   `family` is the supervisor that keeps restarting it.
    func prepareKill(_ family: ProcessFamily, member: ProcessIdentity? = nil, redirectedFrom: String? = nil) {
        guard preparingStop == nil, pendingKill == nil else { return }
        let stop = beginPreparing(family.displayName)
        let returnTo = returnSelection(afterStopping: family)
        Task {
            defer { endPreparing(stop) }
            guard let plan = await killPlan(for: family, member: member) else {
                showToast("This process cannot be targeted", systemImage: "lock")
                return
            }
            await presentPreview(of: plan, for: family, preparing: stop, member: member, learnsFromOutcome: member == nil,
                                 redirectedFrom: redirectedFrom, returnSelection: returnTo)
        }
    }

    /// Shows the preparing state and gives up after 10 s.
    private func beginPreparing(_ name: String) -> PreparingStop {
        let stop = PreparingStop(name: name)
        preparingStop = stop
        expirePreparation(stop)
        return stop
    }

    private func endPreparing(_ stop: PreparingStop) {
        if preparingStop?.id == stop.id { preparingStop = nil }
    }

    private func killPlan(for family: ProcessFamily, member: ProcessIdentity?) async -> KillPlan? {
        let plan = await monitor.killPlan(for: family)
        guard let member else { return plan }
        guard family.canStopIndividually(member),
              let process = family.members.first(where: { $0.identity == member }),
              !process.isSystemProcess else {
            return nil
        }
        return plan.targetingOnly(process)
    }

    /// Stops the supervisor that restarts `family` on exit, through a fresh
    /// preview of the advisor's plan for it.
    func prepareKillSupervisor(of family: ProcessFamily) {
        guard preparingStop == nil, pendingKill == nil else { return }
        let stop = beginPreparing(family.displayName)
        let returnTo = returnSelection(afterStopping: family)
        Task {
            defer { endPreparing(stop) }
            let plan = await monitor.killPlan(for: family)
            let preview = await killer.preview(plan: plan, forceKillDelay: monitor.settings.forceKillDelay)
            guard let supervisor = preview.alternatives.first(where: { $0.kind == .stopSupervisor }) else {
                guard preparingStop?.id == stop.id else { return }
                showToast("\(preview.riskAssessment.supervisor?.name ?? "The supervisor") is no longer running",
                          systemImage: "checkmark.circle")
                return
            }
            await presentAlternative(supervisor.plan, from: family, preparing: stop, returnSelection: returnTo)
        }
    }

    /// The radar family a live process belongs to, for stopping a process
    /// the result of another stop pointed at, such as a port holder.
    func family(containingPID pid: Int32) -> ProcessFamily? {
        monitor.families.first { family in family.members.contains { $0.pid == pid } }
    }

    /// Previews the process holding a port the finished stop should have
    /// freed. The open sheet must be closed first.
    func prepareKill(portHolder pid: Int32) {
        guard let family = family(containingPID: pid),
              let process = family.members.first(where: { $0.pid == pid }) else {
            showToast("That process is no longer running", systemImage: "checkmark.circle")
            return
        }
        prepareKill(family, member: process.identity == family.root.identity ? nil : process.identity)
    }

    /// Previews an alternative the advisor proposed, such as the supervisor
    /// that restarts the family. It replaces any open preview, and the stop
    /// is learned by the family whose root it is. A root no family owns,
    /// like an unlisted pm2 daemon, or one member of a family, is only
    /// audited: its stop says nothing about how that family stops.
    func prepareKill(_ family: ProcessFamily, plan: KillPlan) {
        guard preparingStop == nil else { return }
        let stop = beginPreparing(family.displayName)
        // Replacing an open preview keeps where its stop was started from.
        let returnTo = pendingKill?.returnSelection ?? returnSelection(afterStopping: family)
        Task {
            defer { endPreparing(stop) }
            await presentAlternative(plan, from: family, preparing: stop, returnSelection: returnTo)
        }
    }

    /// A root outside `family`, such as its supervisor, is named in the
    /// sheet's redirect header.
    private func presentAlternative(
        _ plan: KillPlan,
        from family: ProcessFamily,
        preparing stop: PreparingStop,
        returnSelection: RadarFocusedSelection?
    ) async {
        let owner = monitor.families.first { $0.ownedIdentities.contains(plan.rootIdentity) }
        let redirectedFrom = family.ownedIdentities.contains(plan.rootIdentity) ? nil : family.displayName
        await presentPreview(of: plan, for: owner ?? family, preparing: stop, fixedPlan: true,
                             learnsFromOutcome: owner.map { $0.root.identity == plan.rootIdentity } ?? false,
                             redirectedFrom: redirectedFrom,
                             returnSelection: returnSelection)
    }

    /// - Parameter fixedPlan: the plan was not built from `family` (an
    ///   advisor's alternative), so a refresh previews it as it is.
    private func presentPreview(
        of plan: KillPlan,
        for family: ProcessFamily,
        preparing stop: PreparingStop,
        member: ProcessIdentity? = nil,
        fixedPlan: Bool = false,
        learnsFromOutcome: Bool = true,
        redirectedFrom: String? = nil,
        returnSelection: RadarFocusedSelection? = nil
    ) async {
        let delay = monitor.settings.forceKillDelay
        let preview = await killer.preview(plan: plan, forceKillDelay: delay)
        // After the timeout the user was told to try again; a late sheet would surprise them.
        guard preparingStop?.id == stop.id else { return }
        pendingKill = PendingKill(
            family: family,
            preview: preview,
            basePlan: plan,
            member: member,
            replansFromFamily: !fixedPlan,
            forceKillDelay: delay,
            learnsFromOutcome: learnsFromOutcome,
            redirectedFrom: redirectedFrom,
            returnSelection: returnSelection
        )
    }

    /// Previews the open stop again, in place: same sheet, a fresh 60 s
    /// approval, and the one change that matters named in a banner.
    func refreshPendingKill() {
        guard let pending = pendingKill, !isRefreshingPreview else { return }
        isRefreshingPreview = true
        Task {
            defer { isRefreshingPreview = false }
            // The family's current members and sample, so processes started
            // since the first preview are assessed too.
            let family = monitor.families.first { $0.familyKey == pending.family.familyKey } ?? pending.family
            var plan = pending.basePlan
            if pending.replansFromFamily, let fresh = await killPlan(for: family, member: pending.member) {
                plan = fresh
            }
            let preview = await killer.preview(plan: plan, forceKillDelay: pending.forceKillDelay)
            // Closed, confirmed or replaced meanwhile.
            guard pendingKill?.id == pending.id, pendingKill?.preparedAt == pending.preparedAt else { return }
            pendingKill = pending.refreshed(preview: preview, basePlan: plan)
        }
    }

    func confirmKill(
        _ pending: PendingKill,
        skipForce: Bool = false,
        launchdStop: KillLaunchdStop = .none,
        control: KillOperationControl? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        let report = await monitor.confirmKill(
            family: pending.family,
            killer: killer,
            approvedPlan: launchdStop == .none ? pending.plan : pending.plan.stoppingLaunchdJob(launchdStop),
            forceKillDelay: pending.forceKillDelay,
            skipForce: skipForce,
            learnsFromOutcome: pending.learnsFromOutcome,
            control: control,
            eventSink: eventSink
        )
        recordResult(report, of: pending)
        return report
    }

    /// Sends SIGKILL now to what a held stop reported still running, and
    /// to nothing else; nil when nothing survived.
    func forceSurvivors(
        _ pending: PendingKill,
        report: KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport? {
        guard let plan = pending.plan.forcingSurvivors(of: report) else { return nil }
        let forced = await monitor.confirmKill(
            family: pending.family,
            killer: killer,
            approvedPlan: plan,
            forceKillDelay: pending.forceKillDelay,
            learnsFromOutcome: pending.learnsFromOutcome,
            eventSink: eventSink
        )
        recordResult(forced, of: pending)
        return forced
    }

    /// The open sheet looked at its result again and found the app gone:
    /// closing it now behaves as after a clean stop, and the family's page
    /// remembers the settled result. The stop was already learned from.
    func settleStopResult(_ settled: KillReport, of pending: PendingKill) {
        guard lastStopResult?.pendingID == pending.id else { return }
        recordResult(settled, of: pending)
    }

    /// Closing the sheet after this report returns the user and shows its
    /// toast, and the family's page remembers it once the family is gone.
    private func recordResult(_ report: KillReport, of pending: PendingKill) {
        lastStopResult = (pending.id, report)
        rememberStop(report, familyKey: pending.family.familyKey)
    }
}

struct PendingKill: Identifiable {
    /// Kept across refreshes, so the sheet updates instead of re-presenting.
    let id: UUID
    let family: ProcessFamily
    let preview: KillPreview
    /// The plan before it was bound to the previewed processes.
    let basePlan: KillPlan
    /// The single process of a precision stop.
    let member: ProcessIdentity?
    /// A refresh plans again from the family's current members.
    let replansFromFamily: Bool
    let plan: KillPlan
    let forceKillDelay: TimeInterval
    let preparedAt: Date
    let expiresAt: Date
    /// False when the stop is of another process than `family`.
    let learnsFromOutcome: Bool
    /// What a refresh found different from the preview before it.
    let change: KillPreviewChange?
    /// The family the user asked to stop when the target is its supervisor.
    var redirectedFrom: String?
    /// Where to take the user after a clean stop: where they came from.
    var returnSelection: RadarFocusedSelection?

    init(
        id: UUID = UUID(),
        family: ProcessFamily,
        preview: KillPreview,
        basePlan: KillPlan,
        member: ProcessIdentity?,
        replansFromFamily: Bool,
        forceKillDelay: TimeInterval,
        learnsFromOutcome: Bool,
        change: KillPreviewChange? = nil,
        redirectedFrom: String? = nil,
        returnSelection: RadarFocusedSelection? = nil,
        preparedAt: Date = Date()
    ) {
        self.id = id
        self.family = family
        self.preview = preview
        self.basePlan = basePlan
        self.member = member
        self.replansFromFamily = replansFromFamily
        self.forceKillDelay = forceKillDelay
        self.learnsFromOutcome = learnsFromOutcome
        self.change = change
        self.redirectedFrom = redirectedFrom
        self.returnSelection = returnSelection
        self.preparedAt = preparedAt
        expiresAt = preparedAt.addingTimeInterval(60)
        plan = basePlan.binding(to: preview.targetIdentities, expiresAt: expiresAt, profile: preview.strategyProfile,
                                approvedAt: preparedAt)
    }

    func refreshed(preview fresh: KillPreview, basePlan plan: KillPlan) -> PendingKill {
        PendingKill(id: id, family: family, preview: fresh, basePlan: plan, member: member,
                    replansFromFamily: replansFromFamily, forceKillDelay: forceKillDelay,
                    learnsFromOutcome: learnsFromOutcome, change: fresh.materialChange(from: preview),
                    redirectedFrom: redirectedFrom, returnSelection: returnSelection)
    }
}
