import Foundation

/// A stop's outcome in plain words: what happened, the facts worth knowing
/// after it, and what to do next when something is left.
public struct KillOutcomeNarrative: Equatable, Sendable {
    public let headline: String
    public let details: [String]
    public let nextStep: String?

    public init(headline: String, details: [String] = [], nextStep: String? = nil) {
        self.headline = headline
        self.details = details
        self.nextStep = nextStep
    }

    /// Everything, as one paragraph.
    public var text: String {
        ([headline] + (nextStep.map { [$0] } ?? []) + details).joined(separator: " ")
    }
}

/// Tells a stop's outcome from what each process ended as, by name: which
/// exited, which needed force, which are still running and why, and what
/// the stop freed. Port claims come only from the ports actually checked.
public struct KillOutcomeNarrator: Sendable {
    public init() {}

    public func narrate(_ report: KillReport) -> KillOutcomeNarrative {
        let (headline, nextStep) = outcome(of: report)
        var details = report.partiallySucceeded ? report.failures : []
        details += facts(of: report)
        return KillOutcomeNarrative(headline: headline, details: details + report.notes, nextStep: nextStep)
    }

    private func outcome(of report: KillReport) -> (String, String?) {
        let name = report.displayName
        if !report.failures.isEmpty && !report.partiallySucceeded {
            return (report.failures.joined(separator: " "), nil)
        }
        if !report.signalDeniedPIDs.isEmpty && !report.partiallySucceeded {
            return ("macOS refused to stop \(name) (\(Self.pidList(report.signalDeniedPIDs))). It is protected by security software or a system policy; nothing else was tried.", nil)
        }
        if !report.respawnedPIDs.isEmpty {
            let by = report.respawnedBy ?? "a supervisor"
            let advice = report.respawnedBy == "launchd"
                ? "Quit the app or disable the login item that owns it."
                : "Stop \(report.respawnedBy ?? "the supervisor") instead."
            return ("Stopped \(name), but \(by) started it again (\(Self.pidList(report.respawnedPIDs))).", advice)
        }
        let survivors = Self.targets(in: report, state: .survived)
        if !report.survivorPIDs.isEmpty {
            let running = survivors.isEmpty ? Self.pidList(report.survivorPIDs) : Self.names(survivors)
            let verb = max(survivors.count, report.survivorPIDs.count) == 1 ? "is" : "are"
            if report.appStillOpen {
                return ("\(name) is still open; it may be showing a save prompt. Answer it there, or force-stop it.", nil)
            }
            if report.skipForceRequested {
                return ("\(running) \(verb) still running.",
                        "It may be waiting on you, such as a save prompt; force-stop only if you are sure.")
            }
            let forced = !report.forcedPIDs.isEmpty ? ", even after a force stop" : ""
            return ("\(running) \(verb) still running\(forced).", nil)
        }
        let stopped = Self.targets(in: report, state: .terminated) + Self.targets(in: report, state: .forceKilled)
        if report.partiallySucceeded {
            let count = max(stopped.count, Set(report.gracefulPIDs + report.forcedPIDs).count)
            let freed = report.realizedMemoryReclaimBytes > 0 ? " Freed \(RadarFormat.bytes(report.realizedMemoryReclaimBytes))." : ""
            if !report.forcedPIDs.isEmpty {
                let forced = report.forcedPIDs.count
                return ("Stopped \(name); \(forced) process\(forced == 1 ? "" : "es") needed a force stop.\(freed)", nil)
            }
            let helpers = count - 1
            let others = helpers > 0 ? " and \(helpers) helper\(helpers == 1 ? "" : "s")" : ""
            let seconds = report.timeline.totalMilliseconds / 1_000
            let took = seconds >= 1 ? " in \(RadarFormat.seconds(seconds))" : ""
            return ("Stopped \(name)\(others)\(took).\(freed)", nil)
        }
        if let zombieParentName = report.zombieParentName {
            return ("\(name) had already exited; \(zombieParentName) still has to collect it.", nil)
        }
        if !report.deniedPIDs.isEmpty {
            let count = report.deniedPIDs.count
            return ("Nothing was stopped: \(count == 1 ? "the process belongs" : "all \(count) processes belong") to another user or to macOS.", nil)
        }
        if report.stalePIDs.contains(report.rootPID) {
            return ("\(name) had already exited.", nil)
        }
        if !report.stalePIDs.isEmpty || !report.recycledPIDs.isEmpty {
            return ("Nothing was left to stop: the processes exited, or their PIDs now belong to other processes.", nil)
        }
        return ("No owned live processes matched this kill plan.", nil)
    }

    /// What else the user should know, in order of importance.
    private func facts(of report: KillReport) -> [String] {
        var facts: [String] = []
        if !report.signalDeniedPIDs.isEmpty, report.partiallySucceeded {
            facts.append("macOS refused to stop \(Self.pidList(report.signalDeniedPIDs)); it is protected by security software or a system policy.")
        }
        let locked = Set(report.deniedPIDs).subtracting(report.signalDeniedPIDs).count
        if locked > 0, report.partiallySucceeded {
            facts.append("Skipped \(locked) process\(locked == 1 ? "" : "es") that belong\(locked == 1 ? "s" : "") to another user or to macOS.")
        }
        if let bootout = report.launchdBootout, bootout.accepted {
            facts.append("launchd will not start \(bootout.job.label) again \(bootout.disabled ? "until you enable it" : "until the next login").")
        }
        let orphaned = Set(report.leftRunning.map(\.identity))
        let keptRunning = report.lateTargets.filter { $0.state == .locked && !orphaned.contains($0.identity) }
        if !keptRunning.isEmpty {
            facts.append("Kept running after \(report.displayName) stopped: \(Self.names(keptRunning)).")
        }
        if !report.leftRunning.isEmpty {
            facts.append("Left running (now orphaned): \(Self.names(report.leftRunning)).")
        }
        if report.forkStorm {
            facts.append("It kept starting new processes; Ghost froze and stopped \(report.frozenCount) of them. Check that nothing starts it again.")
        }
        facts += report.stuckExitingPIDs.sorted().map {
            "PID \($0) is stuck finishing its exit in the kernel (hung disk or network I/O); it disappears when that I/O completes."
        }
        facts += report.portOutcomes.map(\.text)
        return facts
    }

    /// One row per process, most final state kept.
    private static func targets(in report: KillReport, state: KillTargetState) -> [KillTarget] {
        KillOutcomeRows.make(report: report).filter { $0.state == state }
    }

    private static func names(_ targets: [KillTarget]) -> String {
        let shown = targets.prefix(3).map { "\($0.name) (PID \($0.pid))" }
        let more = targets.count - shown.count
        let list = shown.joined(separator: ", ")
        return more > 0 ? "\(list) and \(more) more" : list
    }

    private static func pidList(_ pids: [Int32]) -> String {
        let sorted = Array(Set(pids)).sorted().map(String.init)
        return "\(sorted.count == 1 ? "PID" : "PIDs") \(sorted.joined(separator: ", "))"
    }
}

public extension KillReport {
    var narrative: KillOutcomeNarrative { KillOutcomeNarrator().narrate(self) }

    /// What to do about what the stop left, when anything is left.
    var nextStep: String? { narrative.nextStep }
}
