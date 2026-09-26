import Foundation

public enum KillAlternativeKind: String, Codable, Sendable {
    /// Stop the supervisor that would restart the family on exit.
    case stopSupervisor
    /// Stop only the member that holds most of the family's footprint.
    case stopHelperOnly
}

/// A better stop than the one previewed: what keeps the family alive, or
/// only the part of it that is the problem.
public struct KillAlternative: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)-\(identity.pid)" }

    public let kind: KillAlternativeKind
    /// The process to stop instead.
    public let identity: ProcessIdentity
    public let title: String
    public let detail: String
    /// Likely better than stopping the whole family.
    public let isRecommended: Bool
    /// Chosen by default: the family's last stop was undone by a restart.
    public let isPreselected: Bool
    /// The stop to preview when chosen; it always gets a fresh preview.
    public let plan: KillPlan

    public init(
        kind: KillAlternativeKind,
        identity: ProcessIdentity,
        title: String,
        detail: String,
        isRecommended: Bool,
        isPreselected: Bool,
        plan: KillPlan
    ) {
        self.kind = kind
        self.identity = identity
        self.title = title
        self.detail = detail
        self.isRecommended = isRecommended
        self.isPreselected = isPreselected
        self.plan = plan
    }
}

/// Suggests stopping what keeps a family alive instead of the family, or
/// only the helper that holds most of it.
public struct KillTargetAdvisor: Sendable {
    /// Share of the family's memory or CPU that makes one member the problem.
    public static let dominantShare = 0.7

    public init() {}

    public func alternatives(
        plan: KillPlan,
        arena: KillGraphArena,
        targets: [KillTarget],
        risk: KillRiskAssessment,
        currentUserID: UInt32
    ) -> [KillAlternative] {
        [supervisorAlternative(plan: plan, arena: arena, targets: targets, risk: risk, currentUserID: currentUserID),
         helperAlternative(plan: plan, targets: targets, risk: risk)].compactMap { $0 }
    }

    /// Only supervisors that restart on exit: stopping the child of pm2 is
    /// undone within a second, while nodemon or watchexec wait for the next
    /// file change, so stopping just their child is usually what you want.
    private func supervisorAlternative(
        plan: KillPlan,
        arena: KillGraphArena,
        targets: [KillTarget],
        risk: KillRiskAssessment,
        currentUserID: UInt32
    ) -> KillAlternative? {
        guard let supervisor = risk.supervisor, let pid = supervisor.pid, Self.restartsOnExit(supervisor.kind) else { return nil }
        let stopping = Set(targets.map(\.identity))
        guard let process = arena.processes(for: pid).first(where: { $0.userID == currentUserID && !stopping.contains($0.identity) }),
              let workload = plan.workload?.rerooted(atAncestor: pid) else { return nil }
        let everyApp = supervisor.kind == .pm2 ? " Stopping PM2 stops every PM2 app." : ""
        return KillAlternative(
            kind: .stopSupervisor,
            identity: process.identity,
            title: "Stop \(supervisor.name) instead",
            detail: "\(supervisor.name) starts \(plan.displayName) again as soon as it exits; stopping \(supervisor.name) keeps it stopped.\(everyApp)",
            isRecommended: true,
            isPreselected: plan.strategyCalibrations.lastStopRespawned,
            plan: KillPlan(rootIdentity: process.identity, targetIdentities: [process.identity], protectedPIDs: [],
                           displayName: supervisor.name, workload: workload)
        )
    }

    private func helperAlternative(plan: KillPlan, targets: [KillTarget], risk: KillRiskAssessment) -> KillAlternative? {
        guard plan.scope == .ownedFamily, targets.count > 1 else { return nil }
        let helpers = targets.filter { $0.identity != plan.rootIdentity }
        let memory = targets.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let cpu = targets.reduce(0) { $0 + $1.cpuPercent }
        let byMemory = helpers.max { $0.memoryBytes < $1.memoryBytes }
        let byCPU = helpers.max { $0.cpuPercent < $1.cpuPercent }
        let dominant: KillTarget
        let freed: String
        if memory > 0, let helper = byMemory, Double(helper.memoryBytes) >= Self.dominantShare * Double(memory) {
            dominant = helper
            freed = "frees \(RadarFormat.bytes(helper.memoryBytes)) of \(RadarFormat.bytes(memory))"
        } else if cpu > 0, let helper = byCPU, helper.cpuPercent >= Self.dominantShare * cpu {
            dominant = helper
            freed = "frees \(Int(helper.cpuPercent.rounded()))% of \(Int(cpu.rounded()))% CPU"
        } else {
            return nil
        }
        let isApp = risk.appQuitPID == plan.rootIdentity.pid
        return KillAlternative(
            kind: .stopHelperOnly,
            identity: dominant.identity,
            title: "Stop only \(dominant.name)",
            detail: "Stop only \(dominant.name): \(freed); \(isApp ? "the app stays open" : "the rest keeps running").",
            isRecommended: isApp,
            isPreselected: false,
            plan: plan.targetingOnly(dominant.identity, name: dominant.name)
        )
    }

    static func restartsOnExit(_ kind: KillSupervisorKind) -> Bool {
        switch kind {
        case .pm2, .forever, .supervisord, .launchd: true
        case .nodemon, .watchexec, .cargoWatch, .air, .tsxWatch, .entr, .overmind: false
        }
    }
}
