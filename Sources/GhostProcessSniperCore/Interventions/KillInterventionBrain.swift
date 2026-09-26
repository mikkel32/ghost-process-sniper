import Darwin
import Foundation

private struct KillPreflightCacheKey: Hashable, Sendable {
    let root: ProcessIdentity
    let targets: [ProcessIdentity]
    let protectedPIDs: [Int32]
    let scope: KillScope
    let approvedIdentities: Set<ProcessIdentity>?
    let approvalExpiresAt: Date?
    let approvedStrategy: KillStrategy?

    init(plan: KillPlan) {
        root = plan.rootIdentity
        targets = plan.targetIdentities.sorted {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            if $0.startTimeSeconds != $1.startTimeSeconds { return $0.startTimeSeconds < $1.startTimeSeconds }
            return $0.startTimeMicroseconds < $1.startTimeMicroseconds
        }
        protectedPIDs = plan.protectedPIDs.sorted()
        scope = plan.scope
        approvedIdentities = plan.approvedIdentities
        approvalExpiresAt = plan.approvalExpiresAt
        approvedStrategy = plan.approvedStrategy
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
