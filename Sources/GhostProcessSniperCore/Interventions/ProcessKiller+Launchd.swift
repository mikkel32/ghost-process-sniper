import Darwin
import Foundation

extension ProcessKiller {
    /// Attaches the launchd job that runs the root, so the risk names what
    /// restarts it and a confirmed stop can boot the job out. Only for a
    /// child of launchd that is not an app: LaunchServices runs those.
    func withLaunchdJob(_ plan: KillPlan) async -> KillPlan {
        guard let resolver = launchdResolver,
              let workload = plan.workload, workload.parentIsLaunchd, workload.launchdJob == nil,
              let root = workload.root, root.pid == plan.rootIdentity.pid,
              !KillRiskAssessor().isAppMainBinary(root),
              let job = await resolver.job(for: plan.rootIdentity, executablePath: root.executablePath) else {
            return plan
        }
        return plan.withLaunchdJob(job)
    }

    /// Boots the root's launchd job out when the plan asks for it: launchd
    /// sends the root SIGTERM itself, honours its ExitTimeOut and does not
    /// start it again. Returns the root's PID when launchd took the request,
    /// so the graceful wave leaves the root to launchd.
    func bootOutLaunchdJob(
        plan: KillPlan,
        targets: [KillTarget],
        operationID: KillOperationID,
        report: inout KillReport,
        eventSink: (@Sendable (KillOperationEvent) -> Void)?
    ) async -> Int32? {
        guard plan.launchdStop != .none, let resolver = launchdResolver,
              let job = plan.workload?.launchdJob, job.pid == plan.rootIdentity.pid,
              let root = targets.first(where: { $0.identity == plan.rootIdentity }) else {
            return nil
        }
        let bootout = await resolver.bootout(job, keepOff: plan.launchdStop == .keepOff)
        report.launchdBootout = bootout
        guard bootout.accepted else {
            appendEvent(.targetUpdated, operationID: operationID, pid: root.pid,
                        message: "launchctl bootout \(job.domainTarget) failed (status \(bootout.status)); signalling \(root.name) instead.",
                        report: &report, eventSink: eventSink)
            return nil
        }
        let attempt = KillAttempt(pid: root.pid, signal: SIGTERM, stage: "graceful", succeeded: true,
                                  message: "Sent by launchd after launchctl bootout \(job.domainTarget).")
        report.attempts.append(attempt)
        if !report.gracefulPIDs.contains(root.pid) { report.gracefulPIDs.append(root.pid) }
        let until = bootout.disabled ? "and kept it off" : "until the next login"
        appendEvent(.signaled, operationID: operationID, pid: root.pid, signalName: attempt.signalName, targetState: .stopping,
                    message: "Booted out the launchd service \(job.label) \(until); launchd is stopping \(root.name).", report: &report, eventSink: eventSink)
        return root.pid
    }
}
