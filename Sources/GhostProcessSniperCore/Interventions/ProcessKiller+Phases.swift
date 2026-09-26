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
}

struct KillPhaseWalk {
    /// Targets still worth verifying: refused and recycled ones are dropped.
    let remaining: [KillTarget]
    /// The app that accepted the quit request.
    let quitAcceptedPID: Int32?
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
        var quitAccepted: Int32?
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
            let recipients = phase.isForce ? live : live.filter { $0.pid != quitAccepted }
            guard !recipients.isEmpty else { continue }
            let stage = phase.isForce ? "forced" : index == 0 ? "graceful" : "secondary"
            if phase.isForce {
                appendEvent(.forcePending, operationID: context.operationID,
                            message: "\(live.count) same-identity target\(live.count == 1 ? "" : "s") still live.",
                            report: &report, eventSink: context.eventSink)
            }
            let dropped = await deliver(phase.action, to: recipients, stage: stage, context: context,
                                        report: &report, quitAccepted: &quitAccepted)
            remaining.removeAll { dropped.contains($0.identity) }
            live.removeAll { dropped.contains($0.identity) }
            guard !live.isEmpty else { break }

            await waitForExit(of: live, phase: phase, isGraceful: index == 0, context: context, report: &report)
            let verifyStage = phase.isForce ? "post-force" : index == 0 ? "pre-force" : "post-secondary"
            let mode = KillVerificationPlanner().mode(stage: verifyStage, hints: await context.reactor.hintSnapshot())
            let verification = try await verify(stage: verifyStage, plan: context.plan, targets: live,
                                                operationStart: context.operationStart, mode: mode, reactor: context.reactor)
            report.verificationPasses.append(verification.pass)
            appendUnique(survivors: verification.recycled.map(\.pid), to: &report.recycledPIDs)
            live = verification.live
            appendEvent(.verified, operationID: context.operationID,
                        message: "\(verifyStage.prefix(1).uppercased())\(verifyStage.dropFirst()) verification: \(verification.pass.livePIDs.count) live, \(verification.pass.recycledPIDs.count) recycled.",
                        report: &report, eventSink: context.eventSink)
        }
        return KillPhaseWalk(remaining: remaining, quitAcceptedPID: quitAccepted)
    }

    /// Sends one phase's action and returns the targets it can never reach:
    /// refused by macOS, or their PID now belongs to another process.
    private func deliver(
        _ action: KillPhaseAction,
        to recipients: [KillTarget],
        stage: String,
        context: KillPhaseContext,
        report: inout KillReport,
        quitAccepted: inout Int32?
    ) async -> Set<ProcessIdentity> {
        let started = Date()
        let attemptsBefore = report.attempts.count
        var sent = action
        var signalled = recipients
        if action == .quitRequest {
            // A quitting app saves its state and closes its own helpers;
            // signalling them now would race that.
            if let pid = context.appQuitPID, let app = recipients.first(where: { $0.pid == pid }),
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
                let outcome = send(signal, to: target, stage: stage, operationID: context.operationID,
                                   report: &report, eventSink: context.eventSink)
                if outcome == .refused || outcome == .recycled {
                    dropped.insert(target.identity)
                }
            }
        }
        await context.reactor.recordWave(
            signalWave(stage: stage, signalName: sent.name, targets: recipients, startedAt: started,
                       attempts: Array(report.attempts.dropFirst(attemptsBefore)))
        )
        return dropped
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
    }
}
