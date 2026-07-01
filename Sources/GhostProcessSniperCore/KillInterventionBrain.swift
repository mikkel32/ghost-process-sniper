import Darwin
import Foundation

private struct KillPreflightCacheKey: Hashable, Sendable {
    let root: ProcessIdentity
    let targets: [ProcessIdentity]
    let protectedPIDs: [Int32]
    let scope: KillScope

    init(plan: KillPlan) {
        root = plan.rootIdentity
        targets = plan.targetIdentities.sorted {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            if $0.startTimeSeconds != $1.startTimeSeconds { return $0.startTimeSeconds < $1.startTimeSeconds }
            return $0.startTimeMicroseconds < $1.startTimeMicroseconds
        }
        protectedPIDs = plan.protectedPIDs.sorted()
        scope = plan.scope
    }
}

public struct KillPreflightCache: Sendable {
    private struct Entry: Sendable {
        var snapshot: KillProcessSnapshot
        var createdAt: Date
    }

    private var entries: [KillPreflightCacheKey: Entry] = [:]

    public init() {}

    mutating func snapshot(for plan: KillPlan, now: Date, ttl: TimeInterval) -> KillProcessSnapshot? {
        let key = KillPreflightCacheKey(plan: plan)
        guard let entry = entries[key] else {
            return nil
        }
        guard now.timeIntervalSince(entry.createdAt) <= ttl else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.snapshot.updatingCacheStatus(.hit)
    }

    mutating func store(_ snapshot: KillProcessSnapshot, for plan: KillPlan, now: Date) {
        entries[KillPreflightCacheKey(plan: plan)] = Entry(
            snapshot: snapshot.updatingCacheStatus(.stored),
            createdAt: now
        )
        if entries.count > 16 {
            let sorted = entries.sorted { $0.value.createdAt < $1.value.createdAt }
            for item in sorted.prefix(entries.count - 16) {
                entries.removeValue(forKey: item.key)
            }
        }
    }
}

public actor KillInterventionBrain {
    private var preflightCache = KillPreflightCache()

    public init() {}

    public func snapshot(
        plan: KillPlan,
        policy: KillSnapshotPolicy,
        provider: KillSnapshotProviding,
        verificationMode: KillVerificationMode = .completeArena,
        now: Date = Date()
    ) async throws -> KillProcessSnapshot {
        let request = KillSnapshotRequest(
            plan: plan,
            policy: policy,
            verificationMode: verificationMode
        )
        if policy == .preflight,
           request.cachePolicy.allowsRead,
           let cached = preflightCache.snapshot(for: plan, now: now, ttl: request.cachePolicy.ttlSeconds) {
            return cached
        }

        let fresh = try await provider.snapshot(request: request)
        let status: KillSnapshotCacheStatus = policy == .preflight ? .miss : .bypassed
        let tagged = fresh.updatingCacheStatus(status)
        if policy == .preflight, request.cachePolicy.allowsWrite {
            preflightCache.store(tagged, for: plan, now: now)
        }
        return tagged
    }

    public nonisolated func decisionScore(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget],
        reclaim: KillReclaimEstimate,
        diff: KillTargetDiff,
        nearbyCount: Int
    ) -> KillDecisionScore {
        var factors: [KillDecisionFactor] = []

        if targets.isEmpty {
            factors.append(
                KillDecisionFactor(
                    kind: .blocking,
                    title: "No owned targets",
                    detail: "No same-user live identity matched the selected tree.",
                    weight: -100
                )
            )
        } else {
            factors.append(
                KillDecisionFactor(
                    kind: .whyKill,
                    title: "Identity verified",
                    detail: "\(targets.count) target\(targets.count == 1 ? "" : "s") matched PID plus start time.",
                    weight: 24
                )
            )
        }

        if reclaim.memoryBytes > 0 || reclaim.cpuPercent > 0 {
            factors.append(
                KillDecisionFactor(
                    kind: .whyKill,
                    title: "Likely reclaim",
                    detail: "\(RadarFormat.bytes(reclaim.memoryBytes)), \(Int(reclaim.cpuPercent.rounded()))% CPU.",
                    weight: min(18, Double(reclaim.memoryBytes) / Double(256 * 1_048_576) * 3 + reclaim.cpuPercent / 8)
                )
            )
        }

        if let metadata = plan.familyMetadata {
            if metadata.scoreLevel >= .hot || metadata.forecastState >= .leaking {
                factors.append(
                    KillDecisionFactor(
                        kind: .whyKill,
                        title: "High-risk radar state",
                        detail: "\(metadata.scoreLevel.label), forecast \(metadata.forecastState.label).",
                        weight: metadata.scoreLevel >= .critical || metadata.forecastState >= .runaway ? 22 : 14
                    )
                )
            }
            if metadata.isBackgroundOrOrphan {
                factors.append(
                    KillDecisionFactor(
                        kind: .whyKill,
                        title: "Background candidate",
                        detail: "The root appears orphaned or backgrounded.",
                        weight: 10
                    )
                )
            }
            if metadata.devKindLabel.localizedCaseInsensitiveContains("build") && metadata.scoreLevel < .critical {
                factors.append(
                    KillDecisionFactor(
                        kind: .whyWait,
                        title: "Active build caution",
                        detail: "Build-like process; interrupt only when stale or critical.",
                        weight: -18
                    )
                )
            }
        }

        if !locked.isEmpty {
            factors.append(
                KillDecisionFactor(
                    kind: .whyWait,
                    title: "Protected descendants",
                    detail: "\(locked.count) locked or foreign process\(locked.count == 1 ? "" : "es") will be skipped.",
                    weight: -min(24, Double(locked.count) * 6)
                )
            )
        }
        if !stale.isEmpty || !recycled.isEmpty || !diff.isEmpty {
            factors.append(
                KillDecisionFactor(
                    kind: .whyWait,
                    title: "Tree drift",
                    detail: diff.summary,
                    weight: -min(20, Double(stale.count + recycled.count + diff.reparentedPIDs.count) * 5)
                )
            )
        }
        if nearbyCount > 0 {
            factors.append(
                KillDecisionFactor(
                    kind: .whyWait,
                    title: "Nearby process group",
                    detail: "\(nearbyCount) same-user neighbor\(nearbyCount == 1 ? "" : "s") shown but not targeted.",
                    weight: -4
                )
            )
        }

        if let history = plan.killHistory, history.operationCount > 0 {
            if history.forceRate >= 0.5 {
                factors.append(
                    KillDecisionFactor(
                        kind: .whyWait,
                        title: "Force history",
                        detail: "\(Int((history.forceRate * 100).rounded()))% of recent interventions required force.",
                        weight: -10
                    )
                )
            }
            if history.gracefulSuccessRate >= 0.65 {
                factors.append(
                    KillDecisionFactor(
                        kind: .whyKill,
                        title: "Graceful history",
                        detail: "\(Int((history.gracefulSuccessRate * 100).rounded()))% recent graceful success.",
                        weight: 8
                    )
                )
            }
            if history.survivorRate >= 0.35 || history.commonDenialCount >= 2 {
                factors.append(
                    KillDecisionFactor(
                        kind: .blocking,
                        title: "Poor intervention history",
                        detail: "Recent interventions had survivors or repeated denials.",
                        weight: -35
                    )
                )
            }
        }

        let raw = factors.reduce(42.0) { $0 + $1.weight }
        let blockingPenalty = factors.contains { $0.kind == .blocking } ? 35.0 : 0
        let confidence = min(1, max(0.2, 0.45 + Double(targets.count) * 0.08 + reclaim.confidence * 0.25 - Double(locked.count) * 0.04))
        return KillDecisionScore(value: raw - blockingPenalty, confidence: confidence, factors: factors)
    }

    public nonisolated func strategyRecommendation(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget],
        decisionScore: KillDecisionScore
    ) -> KillStrategyRecommendation {
        if targets.isEmpty || decisionScore.factors.contains(where: { $0.kind == .blocking }) || locked.count >= max(3, targets.count) {
            return KillStrategyRecommendation(
                strategy: .inspectOnly,
                confidence: max(0.72, decisionScore.confidence),
                reasons: decisionScore.whyWait.prefix(2).map(\.detail).ifEmpty(["Low confidence or too many protected descendants."]),
                previewText: "Inspect only; no signal should be sent until ownership is clearer."
            )
        }

        if let history = plan.killHistory, history.operationCount >= 2 {
            if history.forceRate >= 0.5 {
                return KillStrategyRecommendation(
                    strategy: .stubbornRunaway,
                    confidence: max(0.74, decisionScore.confidence),
                    reasons: ["This family often survives graceful shutdown; expect force verification."],
                    previewText: "SIGTERM, verify, then SIGKILL same-identity survivors if needed."
                )
            }
        }

        let kind = plan.familyMetadata?.devKindLabel.lowercased() ?? plan.displayName.lowercased()
        let devServerHints = ["node", "vite", "python", "ruby", "swift", "server", "bun", "deno", "go service", "php", "dotnet"]
        if devServerHints.contains(where: { kind.contains($0) || plan.displayName.lowercased().contains($0) }) {
            return KillStrategyRecommendation(
                strategy: .gentleDevServer,
                confidence: max(0.76, decisionScore.confidence),
                reasons: ["Looks like a dev server; try SIGINT before SIGTERM."],
                previewText: "SIGINT, verify, then SIGTERM; SIGKILL only for same-identity survivors."
            )
        }

        if plan.familyMetadata?.forecastState == .runaway || plan.familyMetadata?.scoreLevel == .critical || decisionScore.value >= 82 {
            return KillStrategyRecommendation(
                strategy: .stubbornRunaway,
                confidence: max(0.72, decisionScore.confidence),
                reasons: ["Critical, runaway, or high-confidence ghost process; expect possible force escalation."],
                previewText: "SIGTERM, short verification, then SIGKILL same-identity survivors."
            )
        }

        return KillStrategyRecommendation(
            strategy: .standard,
            confidence: max(0.65, decisionScore.confidence),
            reasons: ["Balanced default based on current evidence."],
            previewText: "SIGTERM, verify, then SIGKILL surviving same-identity targets."
        )
    }

    public nonisolated func strategyProfile(
        recommendation: KillStrategyRecommendation,
        forceKillDelay: TimeInterval
    ) -> KillStrategyProfile {
        let schedule: KillVerificationSchedule
        let phases: [KillSignalPhase]
        switch recommendation.strategy {
        case .standard:
            schedule = KillVerificationSchedule(graceSeconds: forceKillDelay, secondaryGraceSeconds: 0.15, settleSeconds: 0.35, allowsSkipForce: true)
            phases = [
                KillSignalPhase(order: 0, label: "Ask target to terminate", signal: SIGTERM, waitAfterSeconds: forceKillDelay, isForce: false),
                KillSignalPhase(order: 1, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
            ]
        case .gentleDevServer:
            schedule = KillVerificationSchedule(graceSeconds: min(forceKillDelay, 1.2), secondaryGraceSeconds: 0.45, settleSeconds: 0.35, allowsSkipForce: true)
            phases = [
                KillSignalPhase(order: 0, label: "Interrupt dev server cleanly", signal: SIGINT, waitAfterSeconds: min(forceKillDelay, 1.2), isForce: false),
                KillSignalPhase(order: 1, label: "Terminate survivors", signal: SIGTERM, waitAfterSeconds: 0.45, isForce: false),
                KillSignalPhase(order: 2, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
            ]
        case .stubbornRunaway:
            schedule = KillVerificationSchedule(graceSeconds: min(forceKillDelay, 0.8), secondaryGraceSeconds: 0.1, settleSeconds: 0.25, allowsSkipForce: true)
            phases = [
                KillSignalPhase(order: 0, label: "Terminate runaway", signal: SIGTERM, waitAfterSeconds: min(forceKillDelay, 0.8), isForce: false),
                KillSignalPhase(order: 1, label: "Force verified survivors", signal: SIGKILL, waitAfterSeconds: 0.25, isForce: true)
            ]
        case .inspectOnly:
            schedule = KillVerificationSchedule(graceSeconds: 0, secondaryGraceSeconds: 0, settleSeconds: 0, allowsSkipForce: false)
            phases = []
        }
        return KillStrategyProfile(
            strategy: recommendation.strategy,
            confidence: recommendation.confidence,
            phases: phases,
            verificationSchedule: schedule,
            summary: recommendation.previewText
        )
    }

    public nonisolated func performanceReport(snapshot: KillProcessSnapshot, eventCoalescingCount: Int = 0) -> KillPerformanceReport {
        KillPerformanceReport(snapshot: snapshot, eventCoalescingCount: eventCoalescingCount)
    }

    public nonisolated func progressViewModel(progress: KillOperationProgress, coalescingWindow: Int = 6) -> KillOperationProgressViewModel {
        KillOperationProgressViewModel(
            progress: progress,
            coalescingWindow: coalescingWindow,
            eventCoalescingCount: max(0, progress.events.count - max(1, coalescingWindow))
        )
    }
}

private extension Array where Element == String {
    func ifEmpty(_ fallback: [String]) -> [String] {
        isEmpty ? fallback : self
    }
}
