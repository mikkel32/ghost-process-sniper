import Foundation

/// Reads the ledger into ranked consumers, and powerd's assertions into sleep
/// blockers attributed to the app or job whose work they serve.
struct EnergyReportBuilder {
    static let consumerLimit = 40
    /// A group is idle when it averaged under 1% of one core for ten minutes.
    static let idleCores = 0.01
    static let idleWatts = 0.05
    /// Keep-awake utilities do this on purpose; they are listed, never flagged.
    static let keepAwakeApps: Set<String> = ["amphetamine", "keepingyouawake", "lungo", "theine", "caffeine",
                                             "caffeinated", "owly", "jolt of caffeine", "one switch"]
    /// Where macOS keeps its daemons and agents; command-line tools in
    /// /usr/bin and /bin are things people run, so they are not listed.
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    let ledger: EnergyLedger
    let battery: BatteryOutlook?
    let processes: [ProcessMetrics]
    let families: [ProcessFamily]
    let now: Date
    /// Each family's workload kind, by family key, for finding rules.
    let classifications: [String: DevProcessKind]
    private let processesByPID: [Int32: ProcessMetrics]

    init(ledger: EnergyLedger, battery: BatteryOutlook?, processes: [ProcessMetrics],
         families: [ProcessFamily], now: Date) {
        self.ledger = ledger
        self.battery = battery
        self.processes = processes
        self.families = families
        self.now = now
        var kinds: [String: DevProcessKind] = [:]
        for family in families { if let kind = family.classification?.kind { kinds[family.familyKey] = kind } }
        classifications = kinds
        var byPID: [Int32: ProcessMetrics] = [:]
        for process in processes {
            if let existing = byPID[process.pid],
               (existing.identity.startTimeSeconds, existing.identity.startTimeMicroseconds) >
                (process.identity.startTimeSeconds, process.identity.startTimeMicroseconds) { continue }
            byPID[process.pid] = process
        }
        processesByPID = byPID
    }

    func consumers() -> [EnergyConsumer] {
        let host = ledger.hostWindow(minutes: 5)
        let draw = battery?.drawWatts
        let discharging = battery?.isDischarging == true
        let remaining = battery?.remainingWattHours
        var result: [EnergyConsumer] = []
        for (key, group) in ledger.groups {
            let recent = ledger.window(key, minutes: 5)
            let hour = ledger.window(key, minutes: EnergyLedger.bucketCount)
            let ten = ledger.window(key, minutes: 10)
            guard group.processCount > 0 || hour.joules > 0.5 || hour.diskBytesWritten > 0 else { continue }
            var gained: Double?
            if discharging, let draw, let remaining, draw > 0.5, group.processCount > 0 {
                // Stopping it cannot remove more than most of the draw; the display and the rest stay.
                let saved = min(recent.watts, draw * 0.9)
                let extra = (remaining / (draw - saved) - remaining / draw) * 60
                gained = extra >= 1 ? extra : nil
            }
            result.append(EnergyConsumer(
                id: key,
                displayName: group.assignment.displayName,
                kind: group.processCount > 1 && group.assignment.kind == .process ? .job : group.assignment.kind,
                applicationPath: group.assignment.applicationPath,
                hostAppName: group.assignment.hostAppName,
                familyKey: group.familyKey,
                isSystem: isSystem(group),
                processCount: group.processCount,
                wattsNow: group.currentWatts,
                averageWatts: recent.watts,
                lastHourWattHours: hour.joules / 3_600,
                idleWakeupsPerSecond: recent.idleWakeupsPerSecond,
                diskWriteBytesPerSecond: recent.diskWriteBytesPerSecond,
                lastHourDiskBytesWritten: hour.diskBytesWritten,
                shareOfMeasured: host.joules > 0 ? min(1, recent.joules / host.joules) : 0,
                batteryMinutesGained: gained,
                observedSeconds: recent.observedSeconds,
                averageCores: recent.cores,
                tenMinuteDiskWriteBytesPerSecond: ten.diskWriteBytesPerSecond,
                tenMinuteObservedSeconds: ten.observedSeconds
            ))
        }
        let energy = ledger.energyAccounted
        result.sort { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            let left = energy ? lhs.averageWatts : lhs.idleWakeupsPerSecond + lhs.diskWriteBytesPerSecond / 100_000
            let right = energy ? rhs.averageWatts : rhs.idleWakeupsPerSecond + rhs.diskWriteBytesPerSecond / 100_000
            if left != right { return left > right }
            if lhs.lastHourWattHours != rhs.lastHourWattHours { return lhs.lastHourWattHours > rhs.lastHourWattHours }
            return lhs.id < rhs.id
        }
        return Array(result.prefix(Self.consumerLimit))
    }

    func blockers(_ assertions: [SleepAssertion], consumers: [EnergyConsumer]) -> [SleepBlocker] {
        var groupByPID: [Int32: String] = [:]
        for (key, group) in ledger.groups { for pid in group.pids { groupByPID[pid] = key } }
        var byKey: [String: SleepBlocker] = [:]
        for assertion in assertions {
            let responsible = assertion.responsiblePID
            let groupKey = groupByPID[responsible]
            let group = groupKey.flatMap { ledger.groups[$0] }
            let process = processesByPID[responsible]
            let name = group?.assignment.displayName ?? process?.name ?? assertion.processName
            let via = assertion.onBehalfOfPID != nil ? assertion.processName : nil
            let intentional = Self.isIntentional(name: name, process: process)
            let system = group.map(isSystem) ?? true
            let idle = groupKey.map(isIdle) ?? false
            let id = "\(groupKey ?? "pid:\(responsible)")|\(assertion.effect.rawValue)"
            let blocker = SleepBlocker(
                id: id, displayName: name, viaProcessName: via, pid: responsible, consumerID: groupKey,
                familyKey: group?.familyKey, effect: assertion.effect, reason: Self.reason(for: assertion),
                rawName: assertion.name, heldSince: assertion.startedAt, isSystem: system,
                isIntentional: intentional, isIdle: idle)
            // One row per holder and effect, dated from its oldest assertion.
            if let existing = byKey[id], let older = existing.heldSince,
               older <= (assertion.startedAt ?? .distantFuture) { continue }
            byKey[id] = blocker
        }
        return byKey.values.sorted { lhs, rhs in
            let left = (lhs.isSystem || lhs.isIntentional ? 1 : 0, lhs.effect == .systemSleep ? 0 : 1)
            let right = (rhs.isSystem || rhs.isIntentional ? 1 : 0, rhs.effect == .systemSleep ? 0 : 1)
            if left != right { return left < right }
            let leftStart = lhs.heldSince ?? now
            let rightStart = rhs.heldSince ?? now
            if leftStart != rightStart { return leftStart < rightStart }
            return lhs.id < rhs.id
        }
    }

    /// Idle means measured for most of the last ten minutes and barely busy.
    func isIdle(_ key: String) -> Bool {
        let window = ledger.window(key, minutes: 10)
        guard window.observedSeconds >= 300 else { return false }
        if window.cores >= Self.idleCores { return false }
        return !ledger.energyAccounted || window.watts < Self.idleWatts
    }

    private func isSystem(_ group: EnergyLedger.Group) -> Bool {
        if group.isSystem { return true }
        if case .knownSource = group.assignment.kind { return true }
        if group.assignment.kind == .app {
            // Apple's own apps are still apps you use.
            return false
        }
        let members = group.pids.compactMap { processesByPID[$0] }
        // Accounts below 500 are macOS's own (root, _coreaudiod, _windowserver…).
        if !members.isEmpty, members.allSatisfy({ $0.userID < 500 }) { return true }
        let paths = members.map(\.executablePath).filter { !$0.isEmpty }
        return !paths.isEmpty && paths.allSatisfy { path in Self.systemPrefixes.contains { path.hasPrefix($0) } }
    }

    static func isIntentional(name: String, process: ProcessMetrics?) -> Bool {
        if keepAwakeApps.contains(name.lowercased()) { return true }
        guard let process, process.name == "caffeinate" else { return false }
        // caffeinate with a timeout, a pid to wait for or a command ends by itself.
        let arguments = process.commandLine.split(separator: " ").dropFirst()
        if arguments.contains(where: { $0.hasPrefix("-t") || $0.hasPrefix("-w") }) { return true }
        return arguments.contains { !$0.hasPrefix("-") }
    }

    static func reason(for assertion: SleepAssertion) -> String {
        if assertion.isAudio {
            let lowered = assertion.name.lowercased()
            return lowered.contains("aggregate") || lowered.contains("input") || lowered.contains("microphone")
                ? "An audio recording or call is open" : "An audio stream is open"
        }
        if assertion.name.hasPrefix("NSURLSessionTask") { return "Finishing a download or upload" }
        if assertion.name == "caffeinate command-line tool" { return "caffeinate is running" }
        if assertion.name.isEmpty || assertion.name == "Electron" {
            return assertion.effect == .displaySleep ? "Asked macOS to keep the display on" : "Asked macOS not to sleep"
        }
        return "\u{201c}\(assertion.name)\u{201d}"
    }
}
