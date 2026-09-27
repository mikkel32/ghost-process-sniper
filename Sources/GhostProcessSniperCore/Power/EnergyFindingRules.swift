import Foundation

/// Decides which energy observations deserve a finding. Thresholds come from
/// macOS's own resource limits where it has one; a finding that is showing
/// stays until its measure falls below 80% of the threshold, so it does not
/// flicker at the edge.
struct EnergyFindingRules: Sendable {
    /// The kernel's wake-ups monitor flags a process above 150 idle wake-ups a
    /// second averaged over five minutes.
    static let wakeupsPerSecond = 150.0
    static let busyWakeupsPerSecond = 500.0
    /// Wake-ups matter when the process is otherwise nearly idle.
    static let wakeupCoreLimit = 0.25
    /// About 1.7 MB/s for ten minutes.
    static let diskBytesPerTenMinutes = 1_073_741_824.0
    static let heavyDiskBytesPerSecond = 20_000_000.0
    static let keepAwakeSeconds: TimeInterval = 30 * 60
    static let longKeepAwakeSeconds: TimeInterval = 2 * 3_600
    static let drainMinimumWatts = 1.5
    static let drainShare = 0.2
    static let drainMinutes = 20.0
    static let hysteresis = 0.8
    /// Workloads whose job is writing a lot: builds, tests, databases, VMs, model downloads.
    static let expectedWriters: Set<DevProcessKind> = [.swiftBuild, .testRunner, .buildWatcher, .dataStore,
                                                       .containerRuntime, .localModelRunner]

    private var since: [String: Date] = [:]

    mutating func evaluate(
        consumers: [EnergyConsumer], blockers: [SleepBlocker], battery: BatteryOutlook?,
        classifications: [String: DevProcessKind], now: Date
    ) -> [EnergyFinding] {
        var findings: [EnergyFinding] = []
        let byID = Dictionary(consumers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for blocker in blockers {
            if let finding = keepsAwake(blocker, consumer: blocker.consumerID.flatMap { byID[$0] },
                                        battery: battery, now: now) {
                findings.append(finding)
            }
        }
        for consumer in consumers where consumer.isRunning && !consumer.isSystem {
            if let finding = wakeups(consumer, battery: battery, now: now) { findings.append(finding) }
            let kind = consumer.familyKey.flatMap { classifications[$0] }
            if let finding = diskWrites(consumer, kind: kind, now: now) { findings.append(finding) }
            if let finding = drain(consumer, battery: battery, now: now) { findings.append(finding) }
        }
        let live = Set(findings.map(\.id))
        since = since.filter { live.contains($0.key) }
        return findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.since != rhs.since { return lhs.since < rhs.since }
            return lhs.id < rhs.id
        }
    }

    private func active(_ id: String) -> Bool { since[id] != nil }

    private func threshold(_ value: Double, _ id: String) -> Double {
        active(id) ? value * Self.hysteresis : value
    }

    private mutating func finding(
        _ kind: EnergyFindingKind, consumerID: String, name: String, familyKey: String?,
        severity: EnergyFindingSeverity, headline: String, detail: String, advice: String, now: Date,
        key: String? = nil
    ) -> EnergyFinding {
        let id = "\(kind.rawValue)|\(key ?? consumerID)"
        let start = since[id] ?? now
        since[id] = start
        return EnergyFinding(id: id, kind: kind, severity: severity, consumerID: consumerID, displayName: name,
                             familyKey: familyKey, headline: headline, detail: detail, advice: advice, since: start)
    }

    // MARK: - Rules

    private mutating func keepsAwake(_ blocker: SleepBlocker, consumer: EnergyConsumer?, battery: BatteryOutlook?,
                                     now: Date) -> EnergyFinding? {
        guard !blocker.isSystem, !blocker.isIntentional, blocker.isIdle,
              let held = blocker.heldFor(at: now) else { return nil }
        // The blocker's id names its holder and effect, so a display and a
        // system assertion from one app are two findings.
        guard held >= threshold(Self.keepAwakeSeconds, "\(EnergyFindingKind.keepsMacAwake.rawValue)|\(blocker.id)") else {
            return nil
        }
        let name = blocker.displayName
        let what = blocker.effect == .displaySleep ? "kept your display on" : "kept your Mac awake"
        let duration = EnergyFormat.duration(held)
        var detail = "\(blocker.reason), and \(name) has used almost no CPU for the last 10 minutes."
        if let via = blocker.viaProcessName { detail += " macOS (\(via)) holds it on \(name)\u{2019}s behalf." }
        let advice: String = if blocker.reason.hasPrefix("An audio") {
            "Close the tab or window that played sound, or quit \(name). Your Mac can sleep again as soon as the stream closes."
        } else if consumer?.kind == .job {
            "If you no longer need it, stop it with Control-C in \(consumer?.hostAppName ?? "its terminal"), or use Stop\u{2026}."
        } else {
            "Quit \(name) if you\u{2019}re not using it. Your Mac can sleep again once it lets go."
        }
        let severity: EnergyFindingSeverity = held >= Self.longKeepAwakeSeconds || battery?.isDischarging == true
            ? .attention : .notable
        return finding(.keepsMacAwake, consumerID: blocker.consumerID ?? blocker.id, name: name,
                       familyKey: blocker.familyKey, severity: severity,
                       headline: "\(name) has \(what) for \(duration)", detail: detail, advice: advice, now: now,
                       key: blocker.id)
    }

    private mutating func wakeups(_ consumer: EnergyConsumer, battery: BatteryOutlook?, now: Date) -> EnergyFinding? {
        let id = "\(EnergyFindingKind.idleWakeups.rawValue)|\(consumer.id)"
        let rate = consumer.idleWakeupsPerSecond
        guard consumer.observedSeconds >= 240, rate >= threshold(Self.wakeupsPerSecond, id) else { return nil }
        let cores = consumer.averageCores
        guard cores < Self.wakeupCoreLimit else { return nil }
        let name = consumer.displayName
        let severity: EnergyFindingSeverity = rate >= Self.busyWakeupsPerSecond ||
            (battery?.isDischarging == true && rate >= 2 * Self.wakeupsPerSecond) ? .attention : .notable
        let count = RadarFormat.fixed0(rate)
        let advice = consumer.kind == .job || consumer.kind == .process
            ? "Check whether \(name) polls in a tight loop, and stop it if it isn\u{2019}t needed."
            : "Look for an animation, a spinning indicator or a busy page in \(name). Quitting and reopening it usually clears this."
        return finding(.idleWakeups, consumerID: consumer.id, name: name, familyKey: consumer.familyKey,
                       severity: severity, headline: "\(name) wakes the processor \(count) times a second",
                       detail: "Averaged over 5 minutes while it used \(RadarFormat.percent(cores * 100)) of one core. macOS itself reports apps above 150 a second: every wake-up stops the processor from resting, which costs battery.",
                       advice: advice, now: now)
    }

    private mutating func diskWrites(_ consumer: EnergyConsumer, kind: DevProcessKind?, now: Date) -> EnergyFinding? {
        guard consumer.knownSource == nil else { return nil }
        let id = "\(EnergyFindingKind.heavyDiskWrites.rawValue)|\(consumer.id)"
        let rate = consumer.tenMinuteDiskWriteBytesPerSecond
        guard consumer.tenMinuteObservedSeconds >= 480 else { return nil }
        let expected = kind.map { Self.expectedWriters.contains($0) } ?? false
        let limit = expected ? Self.heavyDiskBytesPerSecond : Self.diskBytesPerTenMinutes / 600
        guard rate >= threshold(limit, id) else { return nil }
        let name = consumer.displayName
        let perHour = EnergyFormat.bytes(rate * 3_600)
        let advice = consumer.kind == .job || consumer.kind == .process
            ? "If this is a log or cache that keeps growing, stop \(name) or turn its logging down."
            : "Check whether \(name) is syncing, exporting or caching, and pause it if the work can wait."
        return finding(.heavyDiskWrites, consumerID: consumer.id, name: name, familyKey: consumer.familyKey,
                       severity: rate >= Self.heavyDiskBytesPerSecond ? .attention : .notable,
                       headline: "\(name) is writing \(EnergyFormat.bytes(rate))/s to disk",
                       detail: "It has kept this up for 10 minutes, about \(perHour) an hour. Writing without a break wears the SSD and slows other apps.",
                       advice: advice, now: now)
    }

    private mutating func drain(_ consumer: EnergyConsumer, battery: BatteryOutlook?, now: Date) -> EnergyFinding? {
        guard let battery, battery.isDischarging, let draw = battery.drawWatts, draw > 0,
              let gained = consumer.batteryMinutesGained else { return nil }
        let id = "\(EnergyFindingKind.batteryDrain.rawValue)|\(consumer.id)"
        let watts = consumer.averageWatts
        guard consumer.observedSeconds >= 240,
              watts >= threshold(max(Self.drainMinimumWatts, Self.drainShare * draw), id),
              gained >= threshold(Self.drainMinutes, id) else { return nil }
        let name = consumer.displayName
        let advice = consumer.kind == .app
            ? "Close windows or tabs you aren\u{2019}t using, or quit \(name) until you\u{2019}re plugged in."
            : "Let it finish once you\u{2019}re plugged in, or stop it if it can wait."
        return finding(.batteryDrain, consumerID: consumer.id, name: name, familyKey: consumer.familyKey,
                       severity: gained >= 60 ? .attention : .notable,
                       headline: "\(name) is costing about \(EnergyFormat.duration(gained * 60)) of battery",
                       detail: "It used \(EnergyFormat.watts(watts)) of the \(EnergyFormat.watts(draw)) your Mac is drawing, averaged over 5 minutes.",
                       advice: advice, now: now)
    }
}
