import Darwin
import Foundation

public final class ProcessKiller: Sendable {
    let snapshotProvider: KillSnapshotProviding
    let signaler: ProcessSignaling
    let currentUserID: UInt32
    let sleeper: @Sendable (UInt64) async -> Void
    /// Bounds the waits; tests move it with their sleeper instead of the wall.
    let clock: @Sendable () -> Date
    let outcomeClassifier = KillOutcomeClassifier()
    let protection: KillProtectionPolicy
    private let reclaimEstimator = KillReclaimEstimator()
    private let preflightBuilder: KillPreflightBuilder

    public init(
        lookup: ProcessLookup? = nil,
        snapshotProvider: KillSnapshotProviding? = nil,
        signaler: ProcessSignaling = DarwinProcessSignaler(),
        currentUserID: UInt32 = UInt32(geteuid()),
        sleeper: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        clock: @escaping @Sendable () -> Date = { Date() },
        protection: KillProtectionPolicy = KillProtectionPolicy()
    ) {
        if let snapshotProvider {
            self.snapshotProvider = snapshotProvider
        } else if let lookup {
            self.snapshotProvider = ProcessLookupKillSnapshotProvider(lookup: lookup)
        } else {
            self.snapshotProvider = NativeKillSnapshotProvider()
        }
        self.signaler = signaler
        self.currentUserID = currentUserID
        self.protection = protection
        self.preflightBuilder = KillPreflightBuilder(
            currentUserID: currentUserID,
            usesDarwinProcessNamespace: signaler.usesDarwinProcessNamespace,
            protection: protection
        )
        self.sleeper = sleeper
        self.clock = clock
    }

    public func preview(plan: KillPlan, forceKillDelay: TimeInterval = 2) async -> KillPreview {
        await preview(
            plan: plan,
            snapshotPolicy: .preflight,
            profile: .default(gracefulSignal: plan.gracefulSignal, forceKillDelay: forceKillDelay)
        )
    }

    public func preview(
        plan: KillPlan,
        snapshotPolicy: KillSnapshotPolicy,
        profile: KillEscalationProfile
    ) async -> KillPreview {
        do {
            let snapshot = try await snapshotProvider.snapshot(
                request: KillSnapshotRequest(plan: plan, policy: snapshotPolicy)
            )
            let preflight = preflightBuilder.build(plan: plan, snapshot: snapshot, profile: profile)
            RadarLogger.kill.debug("Kill preview \(plan.displayName, privacy: .public) targets \(preflight.preview.targetPIDs.count, privacy: .public) cost \(preflight.preview.preflightMilliseconds, privacy: .public)ms cheap \(preflight.preview.usedCheapSnapshot, privacy: .public)")
            return preflight.preview
        } catch {
            return KillPreview(
                displayName: plan.displayName,
                rootPID: plan.rootIdentity.pid,
                protectedPIDs: plan.protectedPIDs.sorted(),
                forceKillDelay: profile.forceKillDelay,
                staleTargets: plan.targetIdentities.map {
                    KillTarget(unresolved: $0, state: .stale, reason: "Preflight failed")
                },
                readiness: .locked,
                decisionEvidence: [
                    KillDecisionEvidence(
                        kind: .blocking,
                        title: "Preflight failed",
                        detail: error.localizedDescription
                    )
                ]
            )
        }
    }

    /// `forceHeldCheck` holds back force and nothing else: every graceful
    /// wait and polite follow-up still runs. `stopWaitingCheck` ends a wait.
    public func kill(
        plan: KillPlan,
        forceKillDelay: TimeInterval = 2,
        skipForce: Bool = false,
        stopWaitingCheck: (@Sendable () async -> Bool)? = nil,
        forceHeldCheck: (@Sendable () async -> Bool)? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        await kill(
            plan: plan,
            profile: .default(gracefulSignal: plan.gracefulSignal, forceKillDelay: forceKillDelay),
            skipForce: skipForce,
            stopWaitingCheck: stopWaitingCheck,
            forceHeldCheck: forceHeldCheck,
            eventSink: eventSink
        )
    }

    public func kill(
        plan: KillPlan,
        profile: KillEscalationProfile,
        skipForce: Bool = false,
        stopWaitingCheck: (@Sendable () async -> Bool)? = nil,
        forceHeldCheck: (@Sendable () async -> Bool)? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        let totalStart = Date()
        let operationID = KillOperationID()
        let operationState = KillOperationStateMachine(operationID: operationID)
        let reactor = KillInterventionReactor(operationID: operationID)
        var watcherTask: Task<Void, Never>?
        do {
            await reactor.beginPhase("confirm-preflight")
            let preflightSnapshot = try await snapshotProvider.snapshot(
                request: KillSnapshotRequest(plan: plan, policy: .confirm, verificationMode: .completeArena)
            )
            await reactor.endPhase("confirm-preflight")
            let preflight = preflightBuilder.build(plan: plan, snapshot: preflightSnapshot, profile: profile)
            await reactor.recordArenaStats(preflight.preview.arenaStats)
            await reactor.recordCalibration(preflight.preview.strategySimulation)
            let fresh = preflight.preview.strategyProfile
            // The approved phases are the contract; a fresh look may only
            // make the first wait longer.
            let runProfile = (plan.approvedProfile ?? fresh).extendingGrace(to: fresh.graceSeconds)
            let targets = preflight.targets.sorted(by: Self.signalOrder)
            var report = KillReport(
                operationID: operationID,
                displayName: plan.displayName,
                rootPID: plan.rootIdentity.pid,
                deniedPIDs: preflight.preview.deniedPIDs,
                stalePIDs: preflight.preview.stalePIDs,
                exitedBeforeSignalPIDs: preflight.exited.map(\.pid),
                targetResults: preflight.locked + preflight.stale + preflight.recycled + preflight.exited,
                recycledPIDs: preflight.preview.recycledPIDs,
                estimatedMemoryReclaimBytes: preflight.preview.estimatedMemoryReclaimBytes,
                estimatedCPUReclaimPercent: preflight.preview.estimatedCPUReclaimPercent,
                strategyUsed: runProfile.strategy,
                scopeUsed: plan.scope,
                targetDiff: preflight.preview.targetDiff,
                performanceReport: preflight.preview.performanceReport
            )
            report.isForceFollowUp = plan.isForceFollowUp
            report.zombieParentName = preflight.zombieParentName
            appendEvent(.queued, operationID: operationID,
                        message: "Stopping \(targets.count) process\(targets.count == 1 ? "" : "es") with the \(runProfile.strategy.label.lowercased()) strategy.",
                        report: &report, eventSink: eventSink)
            appendEvent(.preflight, operationID: operationID, message: preflight.preview.scopePreview.summary, report: &report, eventSink: eventSink)
            appendEvent(.preflight, operationID: operationID, message: preflight.preview.targetDiff.summary, report: &report, eventSink: eventSink)

            if let expiry = plan.approvalExpiresAt, Date() > expiry {
                report.failures.append("This preview expired. Open a fresh preview before confirming; no signal was sent.")
                return report
            }
            guard preflight.preview.canKill, fresh.strategy != .inspectOnly else {
                if fresh.strategy == .inspectOnly {
                    report.failures.append(Self.inspectOnlyFailure(preflight.preview, approved: plan.approvedProfile != nil))
                }
                report.timeline = KillExecutionTimeline(
                    preflightMilliseconds: preflightSnapshot.elapsedMilliseconds,
                    signalMilliseconds: 0,
                    verificationMilliseconds: 0,
                    totalMilliseconds: Date().timeIntervalSince(totalStart) * 1_000
                )
                return report
            }

            let signalStart = Date()
            if signaler.usesDarwinProcessNamespace {
                let hintStream = KillExitWatcher.watchHints(operationID: operationID, targets: targets)
                watcherTask = Task {
                    for await hint in hintStream {
                        // Forks and execs only steer verification; the
                        // sheet hears about exits.
                        await reactor.recordHint(hint)
                        if hint.kind == .exit {
                            eventSink?(await operationState.recordExit(hint.exitEvent))
                        }
                    }
                }
            }
            let context = KillPhaseContext(
                plan: plan,
                strategy: runProfile.strategy,
                operationID: operationID,
                operationStart: totalStart,
                reactor: reactor,
                operationState: operationState,
                appQuitPID: preflight.preview.riskAssessment.appQuitPID,
                stopWaitingCheck: stopWaitingCheck,
                forceHeld: {
                    if skipForce { return true }
                    return await forceHeldCheck?() == true
                },
                eventSink: eventSink,
                known: Set((preflight.targets + preflight.locked + preflight.stale + preflight.recycled + preflight.exited).map(\.identity)),
                bornAfter: plan.approvedAt ?? preflightSnapshot.sampledAt,
                adoptsLateMembers: plan.scope != .singleRoot
            )
            let walk = try await walk(runProfile.phases, targets: targets, context: context, report: &report)

            let signalMilliseconds = Date().timeIntervalSince(signalStart) * 1_000
            let verifyStart = Date()
            var exitedIdentities = Set<ProcessIdentity>()
            if !walk.remaining.isEmpty {
                let finalMode = KillVerificationPlanner().mode(stage: "final-settle", hints: await reactor.hintSnapshot())
                let finalVerification = try await verify(stage: "final-settle", plan: plan, targets: walk.remaining, operationStart: totalStart, mode: finalMode, reactor: reactor)
                report.verificationPasses.append(finalVerification.pass)
                appendUnique(survivors: finalVerification.recycled.map(\.pid), to: &report.recycledPIDs)
                report.survivorPIDs = finalVerification.live.map(\.pid).sorted()
                report.stuckExitingPIDs = finalVerification.exiting.map(\.pid).sorted()
                exitedIdentities = Set(finalVerification.exited.map(\.identity))
            }
            report.appStillOpen = walk.quitAcceptedPID.map(report.survivorPIDs.contains) ?? false
            let finished = report
            let results = (targets + walk.adopted).map {
                outcomeClassifier.classify(target: $0, report: finished, exitedIdentities: exitedIdentities)
            }
            report.targetResults.append(contentsOf: results)
            // Late processes keep saying where they came from.
            report.lateTargets = zip(walk.adopted, results.suffix(walk.adopted.count)).map {
                $0.updating(state: $1.state, reason: $0.reason)
            } + walk.reportedLate
            report.leftRunning = await orphanedByStop(preflight.locked + walk.reportedLate)
            report.timeline = KillExecutionTimeline(
                preflightMilliseconds: preflightSnapshot.elapsedMilliseconds,
                signalMilliseconds: signalMilliseconds,
                verificationMilliseconds: Date().timeIntervalSince(verifyStart) * 1_000,
                totalMilliseconds: Date().timeIntervalSince(totalStart) * 1_000
            )
            report.targetDiff = KillTargetDiff(
                addedPIDs: preflight.preview.targetDiff.addedPIDs,
                exitedPIDs: report.stalePIDs + report.exitedBeforeSignalPIDs,
                recycledPIDs: report.recycledPIDs,
                reparentedPIDs: preflight.preview.targetDiff.reparentedPIDs,
                survivorPIDs: report.survivorPIDs
            )
            report.finalGraphDelta = KillGraphDelta(
                previewTargetPIDs: preflight.preview.targetPIDs,
                confirmTargetPIDs: targets.map(\.pid),
                finalSurvivorPIDs: report.survivorPIDs,
                drift: report.targetDiff
            )
            report.verificationSnapshotCount = report.verificationPasses.count
            watcherTask?.cancel()
            report.watcherEvents = await operationState.exitEventSnapshot()
            report.reactorReport = await reactor.report()
            report.performanceReport = KillPerformanceReport(
                snapshotMilliseconds: preflight.preview.performanceReport.snapshotMilliseconds,
                graphReadCount: preflight.preview.performanceReport.graphReadCount,
                heavyMetricReadCount: preflight.preview.performanceReport.heavyMetricReadCount,
                targetConversionCount: preflight.preview.performanceReport.targetConversionCount,
                didHitBudget: preflight.preview.performanceReport.didHitBudget,
                skippedOptionalWorkCount: preflight.preview.performanceReport.skippedOptionalWorkCount,
                arenaStats: preflight.preview.arenaStats,
                watcherHintCount: report.reactorReport.watcherHints.count,
                earlyGraceExitCount: report.reactorReport.earlyExitSavingsSeconds > 0 ? 1 : 0,
                targetOnlyVerificationCount: report.reactorReport.verificationModeCounts[KillVerificationMode.targetOnly.rawValue, default: 0],
                completeVerificationCount: report.reactorReport.verificationModeCounts[KillVerificationMode.completeArena.rawValue, default: 0],
                eventTriggeredVerificationCount: report.reactorReport.verificationModeCounts[KillVerificationMode.eventTriggeredComplete.rawValue, default: 0]
            )
            var respawned: [KillProcessLite] = []
            if let supervisor = preflight.preview.riskAssessment.supervisor,
               report.survivorPIDs.isEmpty, report.partiallySucceeded {
                respawned = await detectRespawn(of: targets, by: supervisor, since: walk.lastSignalAt, operationID: operationID,
                                                report: &report, eventSink: eventSink)
            }
            report.realizedMemoryReclaimBytes = reclaimEstimator.realizedEstimate(
                from: preflight.preview.reclaimEstimate,
                targets: report.targetResults,
                respawnedNames: respawned.map(\.name)
            )
            report.calibratedReclaimBytes = report.realizedMemoryReclaimBytes > 0 ?
                report.realizedMemoryReclaimBytes :
                UInt64(Double(report.estimatedMemoryReclaimBytes) * (1 - preflight.preview.survivorRisk))
            appendEvent(.completed, operationID: operationID, message: report.summary, report: &report, eventSink: eventSink)
            RadarLogger.kill.info("Kill operation \(operationID.rawValue, privacy: .public) \(plan.displayName, privacy: .public) finished in \(report.timeline.totalMilliseconds, privacy: .public)ms, forced \(report.forcedPIDs.count, privacy: .public), survivors \(report.survivorPIDs.count, privacy: .public)")
            return report
        } catch {
            watcherTask?.cancel()
            RadarLogger.kill.error("Kill operation \(operationID.rawValue, privacy: .public) failed for \(plan.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return KillReport(
                operationID: operationID,
                displayName: plan.displayName,
                rootPID: plan.rootIdentity.pid,
                failures: [error.localizedDescription],
                timeline: KillExecutionTimeline(
                    preflightMilliseconds: 0,
                    signalMilliseconds: 0,
                    verificationMilliseconds: 0,
                    totalMilliseconds: Date().timeIntervalSince(totalStart) * 1_000
                ),
                eventHistory: [
                    KillOperationEvent(operationID: operationID, kind: .failed, message: error.localizedDescription)
                ],
                scopeUsed: plan.scope
            )
        }
    }

    /// Processes the stop left alone whose parent it took away: they now
    /// run on under launchd. Only asked when something was left alone.
    private func orphanedByStop(_ untouched: [KillTarget]) async -> [KillTarget] {
        let candidates = untouched.filter { $0.parentPID.map { $0 > 1 } == true && $0.identity.startTimeSeconds > 0 }
        guard !candidates.isEmpty,
              let snapshot = try? await snapshotProvider.snapshot(request: KillSnapshotRequest(
                policy: .verify, targetIdentities: candidates.map(\.identity), includeHeavyMetricsForTargets: false,
                requiresCompleteGraph: false, conversionBudget: .targetsOnly, verificationMode: .targetOnly
              )) else { return [] }
        let index = KillProcessIndex(snapshot: snapshot)
        return candidates.filter { target in
            guard let process = index.liteProcess(for: target.identity) else { return false }
            return process.parentPID == 1 && !process.isZombie
        }
        .map { $0.updating(state: .locked, reason: "Left running (now orphaned)") }
    }

    private static func inspectOnlyFailure(_ preview: KillPreview, approved: Bool) -> String {
        guard approved else { return "Inspect-only strategy recommended; no signal sent." }
        let reason = preview.strategyRecommendation.reasons.first.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return "This process changed since the preview\(reason.map { " (\($0))" } ?? ""). Review it again."
    }

    static func signalOrder(_ lhs: KillTarget, _ rhs: KillTarget) -> Bool {
        if lhs.depth != rhs.depth {
            return lhs.depth > rhs.depth
        }
        if lhs.isRoot != rhs.isRoot {
            return !lhs.isRoot
        }
        return lhs.pid > rhs.pid
    }
}
