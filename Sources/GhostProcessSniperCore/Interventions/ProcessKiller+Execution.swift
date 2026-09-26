import Darwin
import Foundation

/// How one signal went, so the caller knows whether to try that target again.
enum KillSendOutcome {
    case sent
    case exited
    /// EPERM: retrying will not change macOS's answer.
    case refused
    /// The PID belongs to another process now; the target is gone.
    case recycled
    case failed
}

extension ProcessKiller {
    func appendEvent(
        _ kind: KillOperationEventKind,
        operationID: KillOperationID,
        pid: Int32? = nil,
        signalName: String? = nil,
        targetState: KillTargetState? = nil,
        message: String,
        waitSeconds: TimeInterval? = nil,
        deadline: Date? = nil,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) {
        let event = KillOperationEvent(
            operationID: operationID,
            kind: kind,
            pid: pid,
            signalName: signalName,
            targetState: targetState,
            message: message,
            waitSeconds: waitSeconds,
            deadline: deadline
        )
        report.eventHistory.append(event)
        eventSink?(event)
    }

    func requestQuit(
        _ target: KillTarget,
        operationID: KillOperationID,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)?
    ) async -> Bool {
        let accepted = await signaler.requestQuit(identity: target.identity)
        let attempt = KillAttempt(
            pid: target.pid,
            action: .quitRequest,
            stage: "graceful",
            succeeded: accepted,
            message: accepted ? "" : "Not a running app; falling back to SIGTERM."
        )
        report.attempts.append(attempt)
        guard accepted else { return false }
        if !report.gracefulPIDs.contains(target.pid) { report.gracefulPIDs.append(target.pid) }
        appendEvent(.signaled, operationID: operationID, pid: target.pid, signalName: attempt.signalName, targetState: .stopping,
                    message: "Asked \(target.name) to quit, like \u{2318}Q.", report: &report, eventSink: eventSink)
        return true
    }

    /// A supervisor restarts what it watches within a moment of its exit.
    /// Looks for a fresh process with a stopped target's name that started
    /// after this operation began.
    func detectRespawn(
        of targets: [KillTarget],
        by supervisor: KillSupervisor,
        since start: Date,
        operationID: KillOperationID,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)?
    ) async {
        await sleeper(1_500_000_000)
        guard let snapshot = try? await snapshotProvider.snapshot(policy: .verify) else { return }
        let lites = snapshot.arena?.processes ?? snapshot.processes.map { KillProcessLite(process: $0) }
        let stoppedNames = Set(targets.map(\.name))
        let stopped = Set(targets.map(\.identity))
        let started = UInt64(max(0, start.timeIntervalSince1970.rounded(.down)))
        let respawned = lites.filter { process in
            !stopped.contains(process.identity) &&
                stoppedNames.contains(process.name) &&
                process.identity.startTimeSeconds >= started &&
                process.userID == currentUserID
        }
        guard !respawned.isEmpty else { return }
        report.respawnedPIDs = respawned.map(\.pid).sorted()
        report.respawnedBy = supervisor.name
        appendEvent(.verified, operationID: operationID,
                    message: "\(supervisor.name) restarted it as PID \(report.respawnedPIDs.map(String.init).joined(separator: ", ")).",
                    report: &report, eventSink: eventSink)
    }

    /// Rows show "Stopping" until an exit is seen; only the exit watcher
    /// and the final classification say a process terminated.
    @discardableResult
    func send(
        _ signal: Int32,
        to target: KillTarget,
        stage: String,
        operationID: KillOperationID,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) -> KillSendOutcome {
        let failed = { (message: String) in KillAttempt(pid: target.pid, signal: signal, stage: stage, succeeded: false, message: message) }
        do {
            try signaler.send(signal: signal, to: target.identity)
            let attempt = KillAttempt(pid: target.pid, signal: signal, stage: stage, succeeded: true)
            report.attempts.append(attempt)
            appendEvent(.signaled, operationID: operationID, pid: target.pid, signalName: attempt.signalName, targetState: stage == "forced" ? .forceKilled : .stopping, message: "\(attempt.signalName) sent to \(target.name).", report: &report, eventSink: eventSink)
            if stage == "forced" {
                if !report.forcedPIDs.contains(target.pid) {
                    report.forcedPIDs.append(target.pid)
                }
            } else if !report.gracefulPIDs.contains(target.pid) {
                report.gracefulPIDs.append(target.pid)
            }
            return .sent
        } catch let failure as SignalFailure where failure.isRecycled {
            report.attempts.append(failed(failure.message))
            appendUnique(survivors: [target.pid], to: &report.recycledPIDs)
            appendEvent(.targetUpdated, operationID: operationID, pid: target.pid, targetState: .recycled, message: "PID \(target.pid) now belongs to another process; nothing was sent.", report: &report, eventSink: eventSink)
            return .recycled
        } catch let failure as SignalFailure where failure.errnoCode == ESRCH {
            report.attempts.append(failed(failure.message))
            if !report.stalePIDs.contains(target.pid) {
                report.stalePIDs.append(target.pid)
            }
            if !report.exitedBeforeSignalPIDs.contains(target.pid) {
                report.exitedBeforeSignalPIDs.append(target.pid)
            }
            appendEvent(.targetUpdated, operationID: operationID, pid: target.pid, targetState: .exitedBeforeSignal, message: "PID exited before signal.", report: &report, eventSink: eventSink)
            return .exited
        } catch let failure as SignalFailure where failure.errnoCode == EPERM {
            report.attempts.append(failed(failure.message))
            appendUnique(survivors: [target.pid], to: &report.deniedPIDs)
            appendUnique(survivors: [target.pid], to: &report.signalDeniedPIDs)
            appendEvent(.targetUpdated, operationID: operationID, pid: target.pid, targetState: .locked, message: "macOS refused to signal \(target.name).", report: &report, eventSink: eventSink)
            return .refused
        } catch {
            let attempt = failed(error.localizedDescription)
            report.attempts.append(attempt)
            report.failures.append("PID \(target.pid) (\(attempt.signalName)): \(error.localizedDescription)")
            appendEvent(.failed, operationID: operationID, pid: target.pid, targetState: .failed, message: error.localizedDescription, report: &report, eventSink: eventSink)
            return .failed
        }
    }

    func signalWave(
        stage: String,
        signalName: String,
        targets: [KillTarget],
        startedAt: Date,
        attempts: [KillAttempt]
    ) -> KillSignalWave {
        KillSignalWave(
            stage: stage,
            signalName: signalName,
            targetPIDs: targets.map(\.pid),
            startedAt: startedAt,
            finishedAt: Date(),
            sentCount: attempts.filter(\.succeeded).count,
            failedCount: attempts.filter { !$0.succeeded }.count
        )
    }

    struct VerificationResult {
        let pass: KillVerificationPass
        let live: [KillTarget]
        let recycled: [KillTarget]
        let exited: [KillTarget]
    }

    func verify(
        stage: String,
        plan: KillPlan,
        targets: [KillTarget],
        operationStart: Date,
        mode: KillVerificationMode = .completeArena,
        reactor: KillInterventionReactor? = nil
    ) async throws -> VerificationResult {
        await reactor?.beginPhase("verify-\(stage)")
        let request = KillSnapshotRequest(
            policy: .verify,
            rootIdentity: plan.rootIdentity,
            targetIdentities: targets.map(\.identity),
            protectedPIDs: plan.protectedPIDs,
            scope: plan.scope,
            budget: .verify,
            includeHeavyMetricsForTargets: false,
            requiresCompleteGraph: mode != .targetOnly,
            conversionBudget: .targetsOnly,
            verificationMode: mode
        )
        let snapshot = try await snapshotProvider.snapshot(request: request)
        await reactor?.endPhase("verify-\(stage)")
        await reactor?.recordVerification(mode: mode)
        if let stats = snapshot.arena?.stats {
            await reactor?.recordArenaStats(stats)
        }
        let index = KillProcessIndex(snapshot: snapshot)
        var live: [KillTarget] = []
        var recycled: [KillTarget] = []
        var exited: [KillTarget] = []

        for target in targets {
            if index.hasRecycledPID(for: target.identity) {
                recycled.append(target)
            } else if let process = index.liteProcess(for: target.identity), !process.isZombie, signaler.exists(pid: target.pid) {
                // A zombie has exited; it only waits for its parent to
                // collect it, and no signal can do more.
                live.append(target)
            } else {
                exited.append(target)
            }
        }

        return VerificationResult(
            pass: KillVerificationPass(
                stage: stage,
                sampledAt: snapshot.sampledAt,
                sampleMilliseconds: snapshot.elapsedMilliseconds,
                elapsedMilliseconds: Date().timeIntervalSince(operationStart) * 1_000,
                livePIDs: live.map(\.pid),
                recycledPIDs: recycled.map(\.pid),
                exitedPIDs: exited.map(\.pid)
            ),
            live: live,
            recycled: recycled,
            exited: exited
        )
    }

    func appendUnique(survivors pids: [Int32], to output: inout [Int32]) {
        for pid in pids where !output.contains(pid) {
            output.append(pid)
        }
        output.sort()
    }
}
