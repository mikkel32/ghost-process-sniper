import Darwin
import Foundation

/// What one stop needs while it walks its phases.
struct KillPhaseContext: Sendable {
    let plan: KillPlan
    let strategy: KillStrategy
    let operationID: KillOperationID
    let operationStart: Date
    let reactor: KillInterventionReactor
    let operationState: KillOperationStateMachine
    let appQuitPID: Int32?
    let stopWaitingCheck: (@Sendable () async -> Bool)?
    let forceHeld: @Sendable () async -> Bool
    let eventSink: (@Sendable (KillOperationEvent) -> Void)?
    /// Every process the confirm snapshot sorted, stopped or not.
    let known: Set<ProcessIdentity>
    /// Processes born after this are new to the stop.
    let bornAfter: Date
    /// False for a single-process stop or a quitting app: what they start
    /// is only reported.
    let adoptsLateMembers: Bool
    /// The root whose launchd job was booted out: launchd already sent it
    /// SIGTERM, so a first phase that would only repeat that leaves it alone.
    let launchdStoppedPID: Int32?
}

struct KillPhaseWalk {
    /// Targets still worth verifying: refused and recycled ones are dropped.
    let remaining: [KillTarget]
    /// The app that accepted the quit request.
    let quitAcceptedPID: Int32?
    /// Processes born during the stop that were stopped with the rest.
    let adopted: [KillTarget]
    /// Processes born during the stop that were only reported.
    let reportedLate: [KillTarget]
    /// When the last signal went out; a restart must come after it.
    let lastSignalAt: Date
}

extension ProcessKiller {
    /// Runs the approved phases in order: act, wait for the exit, verify.
    /// Stops when nothing is left running, and before force when force is
    /// held; the polite phases before it always run.
    func walk(
        _ phases: [KillSignalPhase],
        targets: [KillTarget],
        context: KillPhaseContext,
        report: inout KillReport
    ) async throws -> KillPhaseWalk {
        var remaining = targets
        var live = targets
        var known = context.known
        var adopted: [KillTarget] = []
        var reportedLate: [KillTarget] = []
        var quitAccepted: Int32?
        var lastSignalAt = clock()
        for (index, phase) in phases.enumerated() {
            if index > 0 {
                guard !live.isEmpty else { break }
                if phase.isForce, await context.forceHeld() {
                    report.skipForceRequested = true
                    appendEvent(.forceSkipped, operationID: context.operationID,
                                message: "Force held back; reporting \(live.count) process\(live.count == 1 ? "" : "es") still running.",
                                report: &report, eventSink: context.eventSink)
                    break
                }
            }
            // An app that accepted the quit request may be showing a save
            // prompt, and SIGTERM would close it past that; only force may.
            var recipients = phase.isForce ? live : live.filter { $0.pid != quitAccepted }
            if phase.reach == .rootOnly, !phase.isForce {
                recipients = Self.rootAndOutsiders(of: recipients, tree: targets)
            }
            let launchdStopped = index == 0 && !phase.isForce && live.contains { $0.pid == context.launchdStoppedPID }
            // launchd's SIGTERM stands in for a tree phase or another
            // SIGTERM. A root-only shutdown signal, such as a database's fast
            // shutdown, still goes out; launchd will not restart the root.
            if launchdStopped, phase.reach == .tree || phase.action == .signal(SIGTERM) {
                recipients.removeAll { $0.pid == context.launchdStoppedPID }
                // Only signalled targets are resumed, and a paused root
                // would hold launchd's SIGTERM for the whole wait.
                if let root = live.first(where: { $0.pid == context.launchdStoppedPID }), root.condition == .suspended {
                    resume(root, operationID: context.operationID, report: &report, eventSink: context.eventSink)
                }
            }
            // The root launchd is stopping still gets its full wait.
            guard !recipients.isEmpty || launchdStopped else { continue }
            let stage = phase.isForce ? "forced" : index == 0 ? "graceful" : "secondary"
            let dropped: Set<ProcessIdentity>
            if phase.isForce {
                appendEvent(.forcePending, operationID: context.operationID,
                            message: "\(live.count) same-identity target\(live.count == 1 ? "" : "s") still live.",
                            report: &report, eventSink: context.eventSink)
                let started = Date()
                let attemptsBefore = report.attempts.count
                let force = try await forceTree(live, anchors: remaining, known: &known, context: context, report: &report)
                await context.reactor.recordWave(signalWave(
                    stage: stage, signalName: phase.signalName, targets: force.frozen, startedAt: started,
                    attempts: report.attempts.dropFirst(attemptsBefore).filter { $0.stage == stage }
                ))
                adopted += force.newborn
                remaining += force.newborn
                live += force.newborn
                dropped = force.dropped
            } else if recipients.isEmpty {
                dropped = []
            } else {
                dropped = await deliver(phase, to: recipients, stage: stage, context: context,
                                        report: &report, quitAccepted: &quitAccepted)
            }
            lastSignalAt = clock()
            remaining.removeAll { dropped.contains($0.identity) }
            live.removeAll { dropped.contains($0.identity) }
            guard !live.isEmpty else { break }

            await waitForExit(of: live, phase: phase, isGraceful: index == 0, context: context, report: &report)
            let verifyStage = phase.isForce ? "post-force" : index == 0 ? "pre-force" : "post-secondary"
            var mode = KillVerificationPlanner().mode(stage: verifyStage, hints: await context.reactor.hintSnapshot())
            // A small tree is cheap to list whole, and only a whole list
            // shows what it started while it was asked to stop.
            if !phase.isForce, live.count < 64 { mode = .completeArena }
            let verification = try await verify(stage: verifyStage, plan: context.plan, targets: live,
                                                operationStart: context.operationStart, mode: mode, reactor: context.reactor)
            report.verificationPasses.append(verification.pass)
            appendUnique(survivors: verification.recycled.map(\.pid), to: &report.recycledPIDs)
            live = verification.live
            appendEvent(.verified, operationID: context.operationID,
                        message: "\(verifyStage.prefix(1).uppercased())\(verifyStage.dropFirst()) verification: \(verification.pass.livePIDs.count) live, \(verification.pass.recycledPIDs.count) recycled.",
                        report: &report, eventSink: context.eventSink)

            if !phase.isForce, let arena = verification.arena {
                let late = lateMembers(in: arena, anchors: remaining, known: known, context: context)
                guard !late.isEmpty else { continue }
                known.formUnion(late.map(\.identity))
                if context.adoptsLateMembers, await !context.forceHeld() {
                    adopted += late
                    remaining += late
                    live += late
                    appendEvent(.targetUpdated, operationID: context.operationID,
                                message: "\(late.count) process\(late.count == 1 ? "" : "es") started during the stop; stopping \(late.count == 1 ? "it" : "them") too.",
                                report: &report, eventSink: context.eventSink)
                } else {
                    reportedLate += late.map { $0.updating(state: .locked, reason: "Kept running after \(context.plan.displayName) stopped") }
                }
            }
        }
        return KillPhaseWalk(remaining: remaining, quitAcceptedPID: quitAccepted, adopted: adopted,
                             reportedLate: reportedLate, lastSignalAt: lastSignalAt)
    }

    /// Sends one phase's action and returns the targets it can never reach:
    /// refused by macOS, or their PID now belongs to another process.
    private func deliver(
        _ phase: KillSignalPhase,
        to recipients: [KillTarget],
        stage: String,
        context: KillPhaseContext,
        report: inout KillReport,
        quitAccepted: inout Int32?
    ) async -> Set<ProcessIdentity> {
        let started = Date()
        let attemptsBefore = report.attempts.count
        var sent = phase.action
        var signalled = recipients
        if phase.action == .quitRequest {
            // A quitting app saves its state and closes its own helpers;
            // signalling them now would race that.
            let app = context.appQuitPID.flatMap { pid in recipients.first { $0.pid == pid } }
            if let app, app.condition == .suspended {
                resume(app, operationID: context.operationID, report: &report, eventSink: context.eventSink)
            }
            if let app, let pid = context.appQuitPID,
               await requestQuit(app, operationID: context.operationID, report: &report, eventSink: context.eventSink) {
                quitAccepted = pid
                signalled = []
            } else {
                sent = .signal(SIGTERM)
            }
        }
        var dropped = Set<ProcessIdentity>()
        if case .signal(let signal) = sent {
            for target in signalled {
                let message = phase.reach == .rootOnly && target.isRoot ? "Asked \(target.name) to shut down its workers." : nil
                let outcome = send(signal, to: target, stage: stage, operationID: context.operationID, message: message,
                                   report: &report, eventSink: context.eventSink)
                if outcome == .refused || outcome == .recycled {
                    dropped.insert(target.identity)
                }
                if outcome == .sent, signal != SIGKILL, target.condition == .suspended {
                    resume(target, operationID: context.operationID, report: &report, eventSink: context.eventSink)
                }
            }
        }
        await context.reactor.recordWave(
            signalWave(stage: stage, signalName: sent.name, targets: recipients, startedAt: started,
                       attempts: Array(report.attempts.dropFirst(attemptsBefore)))
        )
        return dropped
    }

    /// The root alone, plus any target outside its tree; everyone when the
    /// root is not among them, since then nothing stops the workers for us.
    static func rootAndOutsiders(of recipients: [KillTarget], tree: [KillTarget]) -> [KillTarget] {
        guard let root = recipients.first(where: \.isRoot) else { return recipients }
        let parents = Dictionary(tree.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        return recipients.filter { target in
            var cursor = target.isRoot ? nil : target.parentPID
            for _ in 0..<64 {
                guard let pid = cursor else { break }
                if pid == root.pid { return false }
                cursor = parents[pid] ?? nil
            }
            return true
        }
    }

    private func waitForExit(
        of group: [KillTarget],
        phase: KillSignalPhase,
        isGraceful: Bool,
        context: KillPhaseContext,
        report: inout KillReport
    ) async {
        if isGraceful, phase.waitAfterSeconds > 0 {
            let held = await context.forceHeld()
            let verb = switch context.strategy {
            case .quitApp: "quit"
            case .carefulShutdown: "shut down cleanly"
            default: "exit"
            }
            appendEvent(.graceWaiting, operationID: context.operationID,
                        message: "Waiting up to \(RadarFormat.seconds(phase.waitAfterSeconds)) for \(context.plan.displayName) to \(verb)\(held ? "; nothing will be forced." : ".")",
                        waitSeconds: phase.waitAfterSeconds, deadline: clock().addingTimeInterval(phase.waitAfterSeconds),
                        report: &report, eventSink: context.eventSink)
        }
        let signaler = signaler
        let operationState = context.operationState
        // A process in a debugger only pauses there; waiting on it would
        // just burn the grace.
        let group = group.filter { $0.condition != .traced }
        let result = await KillGraceCoordinator().wait(
            seconds: phase.waitAfterSeconds,
            sleeper: sleeper,
            now: clock,
            stopWaitingCheck: phase.isForce ? nil : context.stopWaitingCheck
        ) {
            // The exit watcher usually ends a wait early; the kernel check
            // covers targets it cannot watch, and sees zombies as gone.
            let states = await operationState.targetStates()
            return group.allSatisfy { states[$0.pid] == .terminated || signaler.isZombieOrGone(pid: $0.pid) }
        }
        if result.endedEarly, !result.stoppedByUser, !phase.isForce {
            await context.reactor.recordEarlyExitSavings(max(0, phase.waitAfterSeconds - result.waitedSeconds))
        }
        if isGraceful, !phase.isForce {
            // The family's measured exit time, for the outcome model. With
            // every target in a debugger nothing was waited on, so the wait
            // measured no exit.
            report.graceWaitedSeconds = result.waitedSeconds
            report.graceEndedEarly = result.endedEarly && !result.stoppedByUser && !group.isEmpty
            report.graceWatchedNothing = group.isEmpty
        }
    }
}
