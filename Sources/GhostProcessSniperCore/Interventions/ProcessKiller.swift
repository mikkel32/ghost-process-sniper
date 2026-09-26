import Darwin
import Foundation

public final class ProcessKiller: Sendable {
    let snapshotProvider: KillSnapshotProviding
    let signaler: ProcessSignaling
    let currentUserID: UInt32
    let sleeper: @Sendable (UInt64) async -> Void
    let outcomeClassifier = KillOutcomeClassifier()
    let launchdResolver: LaunchdJobResolver?
    let portProbe: ListeningPortProbing?
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
        launchdResolver: LaunchdJobResolver? = nil,
        portProbe: ListeningPortProbing? = nil
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
        self.preflightBuilder = KillPreflightBuilder(
            currentUserID: currentUserID,
            usesDarwinProcessNamespace: signaler.usesDarwinProcessNamespace
        )
        self.sleeper = sleeper
        // Fakes run no launchctl unless tests pass their own.
        let native = signaler.usesDarwinProcessNamespace
        self.launchdResolver = launchdResolver ?? (native ? LaunchdJobResolver(userID: currentUserID) : nil)
        self.portProbe = portProbe ?? (native ? DarwinListeningPortProbe() : nil)
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
        let plan = await withLaunchdJob(plan)
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
                decisionScore: KillDecisionScore(value: 0, confidence: 0, factors: [
                    KillDecisionFactor(kind: .blocking, title: "Preflight failed", detail: error.localizedDescription, weight: -100)
                ])
            )
        }
    }

    public func kill(
        plan: KillPlan,
        forceKillDelay: TimeInterval = 2,
        skipForce: Bool = false,
        skipForceCheck: (@Sendable () async -> Bool)? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        await kill(
            plan: plan,
            profile: .default(gracefulSignal: plan.gracefulSignal, forceKillDelay: forceKillDelay),
            skipForce: skipForce,
            skipForceCheck: skipForceCheck,
            eventSink: eventSink
        )
    }

    public func kill(
        plan: KillPlan,
        profile: KillEscalationProfile,
        skipForce: Bool = false,
        skipForceCheck: (@Sendable () async -> Bool)? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        let totalStart = Date()
        let operationID = KillOperationID()
        let operationState = KillOperationStateMachine(operationID: operationID)
        let reactor = KillInterventionReactor(operationID: operationID)
        let verificationPlanner = KillVerificationPlanner()
        let graceCoordinator = KillGraceCoordinator()
        var watcherTask: Task<Void, Never>?
        let plan = await withLaunchdJob(plan)
        do {
            await reactor.beginPhase("confirm-preflight")
            let preflightSnapshot = try await snapshotProvider.snapshot(
                request: KillSnapshotRequest(plan: plan, policy: .confirm, verificationMode: .completeArena)
            )
            await reactor.endPhase("confirm-preflight")
            let preflight = preflightBuilder.build(plan: plan, snapshot: preflightSnapshot, profile: profile)
            await reactor.recordArenaStats(preflight.preview.arenaStats)
            let freshStrategy = preflight.preview.strategyRecommendation.strategy
            let strategy = freshStrategy == .inspectOnly ? freshStrategy : plan.approvedStrategy ?? freshStrategy
            let strategySignals = strategy.signals(gracefulSignal: profile.gracefulSignal)
            let gracefulSignal = strategySignals.first ?? profile.gracefulSignal
            let escalationSignal = strategy.hasSecondaryStep ? SIGTERM : profile.forcedSignal
            let schedule = preflight.preview.strategyProfile.verificationSchedule
            var report = KillReport(
                operationID: operationID,
                displayName: plan.displayName,
                rootPID: plan.rootIdentity.pid,
                deniedPIDs: preflight.preview.deniedPIDs,
                stalePIDs: preflight.preview.stalePIDs,
                targetResults: preflight.locked + preflight.stale + preflight.recycled,
                recycledPIDs: preflight.preview.recycledPIDs,
                estimatedMemoryReclaimBytes: preflight.preview.estimatedMemoryReclaimBytes,
                estimatedCPUReclaimPercent: preflight.preview.estimatedCPUReclaimPercent,
                skipForceRequested: skipForce,
                strategyUsed: strategy,
                scopeUsed: plan.scope,
                targetDiff: preflight.preview.targetDiff,
                performanceReport: preflight.preview.performanceReport
            )
            appendEvent(.queued, operationID: operationID, message: "Queued \(strategy.label) intervention.", report: &report, eventSink: eventSink)
            appendEvent(.preflight, operationID: operationID, message: preflight.preview.scopePreview.summary, report: &report, eventSink: eventSink)
            appendEvent(.preflight, operationID: operationID, message: preflight.preview.targetDiff.summary, report: &report, eventSink: eventSink)

            if let expiry = plan.approvalExpiresAt, Date() > expiry {
                report.failures.append("This preview expired. Open a fresh preview before confirming; no signal was sent.")
                return report
            }
            guard preflight.preview.canKill, strategy != .inspectOnly else {
                if strategy == .inspectOnly {
                    report.failures.append("Inspect-only strategy recommended; no signal sent.")
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
            let targets = preflight.targets.sorted(by: Self.signalOrder)
            let signaler = signaler
            // The exit watcher usually ends a grace period early; a cheap
            // existence check covers the times it cannot run.
            @Sendable func allExited(_ group: [KillTarget]) async -> Bool {
                guard !group.isEmpty else { return false }
                let states = await operationState.targetStates()
                return group.allSatisfy { states[$0.pid] == .terminated || !signaler.exists(pid: $0.pid) }
            }
            if signaler.usesDarwinProcessNamespace {
                let hintStream = KillExitWatcher.watchHints(operationID: operationID, targets: targets)
                watcherTask = Task {
                    for await hint in hintStream {
                        await reactor.recordHint(hint)
                        if hint.kind == .exit {
                            let update = await operationState.recordExit(hint.exitEvent)
                            eventSink?(update)
                        } else {
                            eventSink?(
                                KillOperationEvent(
                                    operationID: operationID,
                                    kind: .targetUpdated,
                                    pid: hint.pid,
                                    message: hint.message,
                                    createdAt: hint.observedAt
                                )
                            )
                        }
                    }
                }
            }
            let gracefulWaveStarted = Date()
            let attemptsBeforeGrace = report.attempts.count
            for target in targets {
                appendEvent(.targetUpdated, operationID: operationID, pid: target.pid, targetState: .ready, message: "Queued \(target.name).", report: &report, eventSink: eventSink)
            }
            let launchdStoppedPID = await bootOutLaunchdJob(plan: plan, targets: targets, operationID: operationID, report: &report, eventSink: eventSink)
            if gracefulSignal == KillSignalPhase.quitRequest {
                // A quitting app saves its state and closes its own helpers;
                // signalling them now would race that. Anything left after
                // the grace period is handled by the next step.
                var asked = false
                if let quitPID = preflight.preview.riskAssessment.appQuitPID,
                   let app = targets.first(where: { $0.pid == quitPID }) {
                    asked = await requestQuit(app, operationID: operationID, report: &report, eventSink: eventSink)
                }
                if !asked {
                    for target in targets where target.pid != launchdStoppedPID {
                        send(SIGTERM, to: target, stage: "graceful", operationID: operationID, report: &report, eventSink: eventSink)
                    }
                }
            } else {
                for target in targets where target.pid != launchdStoppedPID {
                    send(gracefulSignal, to: target, stage: "graceful", operationID: operationID, report: &report, eventSink: eventSink)
                }
            }
            await reactor.recordWave(
                signalWave(
                    stage: "graceful",
                    signal: gracefulSignal,
                    targets: targets,
                    startedAt: gracefulWaveStarted,
                    attempts: Array(report.attempts.dropFirst(attemptsBeforeGrace))
                )
            )

            appendEvent(.graceWaiting, operationID: operationID, message: "Waiting \(String(format: "%.1f", schedule.graceSeconds))s before force verification.", report: &report, eventSink: eventSink)
            let graceResult = await graceCoordinator.wait(
                seconds: schedule.graceSeconds,
                sleeper: sleeper,
                skipForceCheck: skipForceCheck
            ) {
                await allExited(targets)
            }
            report.graceWaitedSeconds = graceResult.waitedSeconds
            report.graceEndedEarly = graceResult.endedEarly && !graceResult.skipForceRequested
            if graceResult.endedEarly && !graceResult.skipForceRequested {
                await reactor.recordEarlyExitSavings(max(0, schedule.graceSeconds - graceResult.waitedSeconds))
            }
            let preForceHints = await reactor.hintSnapshot()
            let preForceMode = verificationPlanner.mode(
                stage: "pre-force",
                hints: preForceHints
            )
            let preForce = try await verify(stage: "pre-force", plan: plan, targets: targets, operationStart: totalStart, mode: preForceMode, reactor: reactor)
            report.verificationPasses.append(preForce.pass)
            appendUnique(survivors: preForce.recycled.map(\.pid), to: &report.recycledPIDs)
            var latestLiveTargets = preForce.live
            appendEvent(.verified, operationID: operationID, message: "Pre-force verification: \(preForce.pass.livePIDs.count) live, \(preForce.pass.recycledPIDs.count) recycled.", report: &report, eventSink: eventSink)

            var shouldSkipForce = skipForce || graceResult.skipForceRequested
            if !shouldSkipForce, let skipForceCheck {
                shouldSkipForce = await skipForceCheck()
            }
            report.skipForceRequested = shouldSkipForce
            if shouldSkipForce {
                report.survivorPIDs = latestLiveTargets.map(\.pid).sorted()
                appendEvent(.forceSkipped, operationID: operationID, message: "Force escalation skipped by user.", report: &report, eventSink: eventSink)
            } else if !latestLiveTargets.isEmpty {
                appendEvent(.forcePending, operationID: operationID, message: "\(latestLiveTargets.count) same-identity target\(latestLiveTargets.count == 1 ? "" : "s") still live.", report: &report, eventSink: eventSink)
                let escalationWaveStarted = Date()
                let attemptsBeforeEscalation = report.attempts.count
                for target in latestLiveTargets {
                    send(escalationSignal, to: target, stage: strategy.hasSecondaryStep ? "secondary" : "forced", operationID: operationID, report: &report, eventSink: eventSink)
                }
                await reactor.recordWave(
                    signalWave(
                        stage: strategy.hasSecondaryStep ? "secondary" : "forced",
                        signal: escalationSignal,
                        targets: latestLiveTargets,
                        startedAt: escalationWaveStarted,
                        attempts: Array(report.attempts.dropFirst(attemptsBeforeEscalation))
                    )
                )
                let secondaryTargets = latestLiveTargets
                let secondaryGrace = await graceCoordinator.wait(seconds: schedule.secondaryGraceSeconds, sleeper: sleeper) {
                    await allExited(secondaryTargets)
                }
                if secondaryGrace.endedEarly {
                    await reactor.recordEarlyExitSavings(max(0, schedule.secondaryGraceSeconds - secondaryGrace.waitedSeconds))
                }
                let postForceHints = await reactor.hintSnapshot()
                let postForceMode = verificationPlanner.mode(
                    stage: "post-force",
                    hints: postForceHints
                )
                let postForce = try await verify(stage: "post-force", plan: plan, targets: targets, operationStart: totalStart, mode: postForceMode, reactor: reactor)
                report.verificationPasses.append(postForce.pass)
                appendUnique(survivors: postForce.recycled.map(\.pid), to: &report.recycledPIDs)
                latestLiveTargets = postForce.live
                appendEvent(.verified, operationID: operationID, message: "Post-force verification: \(postForce.pass.livePIDs.count) live.", report: &report, eventSink: eventSink)
                if strategy.hasSecondaryStep && !latestLiveTargets.isEmpty {
                    appendEvent(.forcePending, operationID: operationID, message: "Gentle stop left \(latestLiveTargets.count) target\(latestLiveTargets.count == 1 ? "" : "s"); preparing SIGKILL.", report: &report, eventSink: eventSink)
                    let forceWaveStarted = Date()
                    let attemptsBeforeForce = report.attempts.count
                    for target in latestLiveTargets {
                        send(profile.forcedSignal, to: target, stage: "forced", operationID: operationID, report: &report, eventSink: eventSink)
                    }
                    await reactor.recordWave(
                        signalWave(
                            stage: "forced",
                            signal: profile.forcedSignal,
                            targets: latestLiveTargets,
                            startedAt: forceWaveStarted,
                            attempts: Array(report.attempts.dropFirst(attemptsBeforeForce))
                        )
                    )
                }
                _ = await graceCoordinator.wait(seconds: schedule.settleSeconds, sleeper: sleeper) {
                    await allExited(targets)
                }
            }

            let signalMilliseconds = Date().timeIntervalSince(signalStart) * 1_000
            let verifyStart = Date()
            let finalHints = await reactor.hintSnapshot()
            let finalMode = verificationPlanner.mode(
                stage: "final-settle",
                hints: finalHints
            )
            let finalVerification = try await verify(stage: "final-settle", plan: plan, targets: targets, operationStart: totalStart, mode: finalMode, reactor: reactor)
            report.verificationPasses.append(finalVerification.pass)
            appendUnique(survivors: finalVerification.recycled.map(\.pid), to: &report.recycledPIDs)
            let finalSurvivors = finalVerification.live
            report.survivorPIDs = finalSurvivors.map(\.pid).sorted()
            report.targetResults.append(contentsOf: finalResults(for: targets, report: report))
            report.realizedMemoryReclaimBytes = reclaimEstimator.realizedEstimate(
                from: preflight.preview.reclaimEstimate,
                targets: report.targetResults
            )
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
            report.calibratedReclaimBytes = report.realizedMemoryReclaimBytes
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
            if let supervisor = preflight.preview.riskAssessment.supervisor,
               report.survivorPIDs.isEmpty, report.partiallySucceeded {
                await detectRespawn(of: targets, by: supervisor, since: totalStart, operationID: operationID, report: &report, eventSink: eventSink)
            }
            await verifyFreedPorts(preflight.preview.riskAssessment.freedPorts, targets: targets, groupsFrom: preflightSnapshot.arena,
                                   since: totalStart, operationID: operationID, report: &report, eventSink: eventSink)
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
