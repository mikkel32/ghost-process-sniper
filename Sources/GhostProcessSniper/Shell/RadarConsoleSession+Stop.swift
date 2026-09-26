import Foundation
import GhostProcessSniperCore

/// Stopping processes: previews, the in-place refresh, confirming, and the
/// follow-ups a finished stop offers.
extension RadarConsoleSession {
    func prepareKill(_ family: ProcessFamily, member: ProcessIdentity? = nil) {
        guard !isPreparingIntervention, pendingKill == nil else { return }
        isPreparingIntervention = true
        Task {
            defer { isPreparingIntervention = false }
            guard let plan = await killPlan(for: family, member: member) else {
                showToast("This process cannot be targeted", systemImage: "lock")
                return
            }
            await presentPreview(of: plan, for: family, member: member)
        }
    }

    private func killPlan(for family: ProcessFamily, member: ProcessIdentity?) async -> KillPlan? {
        let plan = await monitor.killPlan(for: family)
        guard let member else { return plan }
        guard family.ownedIdentities.contains(member),
              let process = family.members.first(where: { $0.identity == member }),
              !process.isSystemProcess else {
            return nil
        }
        return plan.targetingOnly(process)
    }

    /// Stops the supervisor that restarts `family` on exit, through a fresh
    /// preview of the advisor's plan for it.
    func prepareKillSupervisor(of family: ProcessFamily) {
        guard !isPreparingIntervention, pendingKill == nil else { return }
        isPreparingIntervention = true
        Task {
            defer { isPreparingIntervention = false }
            let plan = await monitor.killPlan(for: family)
            let preview = await killer.preview(plan: plan, forceKillDelay: monitor.settings.forceKillDelay)
            guard let supervisor = preview.alternatives.first(where: { $0.kind == .stopSupervisor }) else {
                showToast("\(preview.riskAssessment.supervisor?.name ?? "The supervisor") is no longer running",
                          systemImage: "checkmark.circle")
                return
            }
            await presentAlternative(supervisor.plan, from: family)
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
    /// is learned by the family that owns the new root. A root no family
    /// owns, like an unlisted pm2 daemon, is only audited: its stop says
    /// nothing about how `family` stops.
    func prepareKill(_ family: ProcessFamily, plan: KillPlan) {
        guard !isPreparingIntervention else { return }
        isPreparingIntervention = true
        Task {
            defer { isPreparingIntervention = false }
            await presentAlternative(plan, from: family)
        }
    }

    private func presentAlternative(_ plan: KillPlan, from family: ProcessFamily) async {
        if let owner = monitor.families.first(where: { $0.ownedIdentities.contains(plan.rootIdentity) }) {
            await presentPreview(of: plan, for: owner, fixedPlan: true)
        } else {
            await presentPreview(of: plan, for: family, fixedPlan: true, learnsFromOutcome: false)
        }
    }

    /// - Parameter fixedPlan: the plan was not built from `family` (an
    ///   advisor's alternative), so a refresh previews it as it is.
    private func presentPreview(
        of plan: KillPlan,
        for family: ProcessFamily,
        member: ProcessIdentity? = nil,
        fixedPlan: Bool = false,
        learnsFromOutcome: Bool = true
    ) async {
        let delay = monitor.settings.forceKillDelay
        let preview = await killer.preview(plan: plan, forceKillDelay: delay)
        pendingKill = PendingKill(
            family: family,
            preview: preview,
            basePlan: plan,
            member: member,
            replansFromFamily: !fixedPlan,
            forceKillDelay: delay,
            learnsFromOutcome: learnsFromOutcome
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
        await monitor.confirmKill(
            family: pending.family,
            killer: killer,
            approvedPlan: launchdStop == .none ? pending.plan : pending.plan.stoppingLaunchdJob(launchdStop),
            forceKillDelay: pending.forceKillDelay,
            skipForce: skipForce,
            learnsFromOutcome: pending.learnsFromOutcome,
            control: control,
            eventSink: eventSink
        )
    }

    /// Sends SIGKILL now to what a held stop reported still running, and
    /// to nothing else; nil when nothing survived.
    func forceSurvivors(
        _ pending: PendingKill,
        report: KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport? {
        guard let plan = pending.plan.forcingSurvivors(of: report) else { return nil }
        return await monitor.confirmKill(
            family: pending.family,
            killer: killer,
            approvedPlan: plan,
            forceKillDelay: pending.forceKillDelay,
            learnsFromOutcome: pending.learnsFromOutcome,
            eventSink: eventSink
        )
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
        self.preparedAt = preparedAt
        expiresAt = preparedAt.addingTimeInterval(60)
        plan = basePlan.binding(to: preview.targetIdentities, expiresAt: expiresAt, profile: preview.strategyProfile,
                                approvedAt: preparedAt)
    }

    func refreshed(preview fresh: KillPreview, basePlan plan: KillPlan) -> PendingKill {
        PendingKill(id: id, family: family, preview: fresh, basePlan: plan, member: member,
                    replansFromFamily: replansFromFamily, forceKillDelay: forceKillDelay,
                    learnsFromOutcome: learnsFromOutcome, change: fresh.materialChange(from: preview))
    }
}
