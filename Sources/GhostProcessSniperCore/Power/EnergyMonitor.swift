import Foundation

/// Owns the energy ledger, the battery and the sleep assertions, and turns
/// them into an `EnergyReport` once per refresh. Lives on the refresh worker;
/// the battery and powerd are asked on their own, slower cadence.
struct EnergyMonitor: Sendable {
    /// How often the battery and powerd are asked, visible and hidden.
    static let batteryInterval: (visible: TimeInterval, hidden: TimeInterval) = (2, 15)
    static let assertionInterval: (visible: TimeInterval, hidden: TimeInterval) = (5, 30)
    /// Time constant of the snapshot draw average, used while the power
    /// controller's counters have not yet made an interval (and on Macs
    /// without them): long enough to hold still, short enough to follow a
    /// change of work within a minute or two.
    static let drawTimeConstant: TimeInterval = 60
    /// The draw behind the time left is the counters' mean over about this long.
    static let drawWindow: TimeInterval = 90
    /// The window the per-app figures cover, so the Mac's draw and the apps' share compare like with like.
    static let averageWindow: TimeInterval = 300

    private let batterySource: (any BatterySource)?
    private let assertionSource: (any SleepAssertionSource)?
    private(set) var ledger = EnergyLedger()
    private var battery: BatteryReading?
    private var smoothedDraw: (watts: Double, at: Date, discharging: Bool)?
    private var loadAverager = DrawAverager()
    /// The header's state, kept between reads so a flow at a threshold does not flip it.
    private var powerState: PowerState?
    private var assertions: [SleepAssertion] = []
    private var assertionsReadAt: Date?
    private var rules = EnergyFindingRules()
    private var familyFigures: [String: FamilyPowerFigures] = [:]
    private var history: EnergyHistoryTracker

    init(battery: (any BatterySource)? = IOKitBatterySource(),
         assertions: (any SleepAssertionSource)? = IOKitSleepAssertionSource(), persistsHistory: Bool = false) {
        batterySource = battery
        assertionSource = assertions
        history = EnergyHistoryTracker(persists: persistsHistory)
    }

    mutating func update(
        processes: [ProcessMetrics], families: [ProcessFamily],
        responsiblePIDs: [ProcessIdentity: Int32], uiVisible: Bool, now: Date
    ) -> EnergyReport {
        var resolver = ThermalWorkloadResolver(processes: processes, responsiblePIDs: responsiblePIDs)
        return update(processes: processes, families: families, resolver: &resolver, uiVisible: uiVisible, now: now)
    }

    /// `resolver` is shared with the heat panel's projection of the same scan.
    mutating func update(
        processes: [ProcessMetrics], families: [ProcessFamily],
        resolver: inout ThermalWorkloadResolver, uiVisible: Bool, now: Date
    ) -> EnergyReport {
        let owners = Self.ownership(families)
        ledger.record(processes: processes, now: now, assign: { process in
            let assignment = resolver.assignment(for: process)
            return EnergyGroupAssignment(key: assignment.groupKey, displayName: assignment.displayName,
                                         kind: assignment.kind, applicationPath: assignment.applicationPath,
                                         hostAppName: assignment.hostAppName)
        }, familyKey: { owners[$0.identity] })
        history.record(ledger.tickCharges.compactMap { key, charge in ledger.groups[key].map { ($0.assignment, charge) } },
                       now: now)

        readBattery(uiVisible: uiVisible, now: now)
        readAssertions(uiVisible: uiVisible, now: now)

        let outlook = self.outlook(now: now)
        var measured = 0
        for process in processes where process.power.measuredAt == process.sampledAt { measured += 1 }
        let builder = EnergyReportBuilder(ledger: ledger, battery: outlook, processes: processes,
                                          families: families, now: now)
        let consumers = builder.consumers()
        let blockers = builder.blockers(assertions)
        let findings = rules.evaluate(consumers: consumers, blockers: blockers, battery: outlook,
                                      classifications: builder.classifications, now: now)
        updateFamilies(families, blockers: blockers, now: now)
        let host = ledger.hostWindow(minutes: 5)
        return EnergyReport(
            generatedAt: now,
            perProcessEnergy: ledger.energyAccounted,
            battery: outlook,
            measuredWatts: host.watts,
            lastHourWattHours: ledger.hostWindow(minutes: EnergyLedger.bucketCount).joules / 3_600,
            consumers: consumers,
            blockers: blockers,
            findings: findings,
            minuteWatts: ledger.host.map(\.watts),
            measuredProcessCount: measured,
            unmeasuredProcessCount: processes.count - measured,
            families: familyFigures,
            today: history.summary(fullChargeWattHours: battery?.hasBattery == true ? battery?.fullChargeWattHours : nil,
                                   now: now)
        )
    }

    // MARK: - Daily history (the worker does the store's async calls)

    func needsHistoryLoad(now: Date) -> Bool { history.needsLoad(now: now) }
    mutating func loadHistory(_ rows: [EnergyDayUsage], now: Date) { history.load(rows, now: now) }
    mutating func noteHistoryLoadFailed(now: Date) { history.noteLoadFailed(now: now) }
    mutating func takeHistoryFlush(now: Date, force: Bool = false) -> [(day: String, usages: [EnergyUsage])]? {
        history.takeFlush(now: now, force: force)
    }
    mutating func restoreHistory(_ batches: [(day: String, usages: [EnergyUsage])]) { history.restore(batches) }

    /// Averages each family's member rates over about a minute, so a family
    /// page reads a steady figure rather than one scan's.
    private mutating func updateFamilies(_ families: [ProcessFamily], blockers: [SleepBlocker], now: Date) {
        var effects: [Int32: SleepAssertionEffect] = [:]
        for blocker in blockers where effects[blocker.pid] != .systemSleep { effects[blocker.pid] = blocker.effect }
        var next: [String: FamilyPowerFigures] = [:]
        for family in families {
            var watts = 0.0, wakeups = 0.0, writes = 0.0
            var measured = false
            var effect: SleepAssertionEffect?
            for member in family.members {
                let power = member.power
                if power.measuredAt == member.sampledAt, let value = power.watts {
                    measured = true
                    watts += value
                    wakeups += power.wakeupsPerSecond ?? 0
                    writes += power.diskWriteBytesPerSecond ?? 0
                }
                if let held = effects[member.pid], effect != .systemSleep { effect = held }
            }
            guard measured else {
                if var kept = familyFigures[family.familyKey] {
                    kept.keepsAwake = effect
                    next[family.familyKey] = kept
                }
                continue
            }
            var figures = FamilyPowerFigures(watts: watts, wakeupsPerSecond: wakeups,
                                             diskWriteBytesPerSecond: writes, keepsAwake: effect, updatedAt: now)
            if let previous = familyFigures[family.familyKey], now > previous.updatedAt {
                let alpha = 1 - exp(-now.timeIntervalSince(previous.updatedAt) / Self.drawTimeConstant)
                figures.watts = previous.watts + alpha * (watts - previous.watts)
                figures.wakeupsPerSecond = previous.wakeupsPerSecond + alpha * (wakeups - previous.wakeupsPerSecond)
                figures.diskWriteBytesPerSecond = previous.diskWriteBytesPerSecond +
                    alpha * (writes - previous.diskWriteBytesPerSecond)
            }
            next[family.familyKey] = figures
        }
        familyFigures = next
    }

    /// The family that owns each process; the alphabetically first wins a tie,
    /// as in the heat panel.
    static func ownership(_ families: [ProcessFamily]) -> [ProcessIdentity: String] {
        var owners: [ProcessIdentity: String] = [:]
        for family in families {
            for member in family.members {
                if let existing = owners[member.identity], existing <= family.familyKey { continue }
                owners[member.identity] = family.familyKey
            }
            if owners[family.root.identity] == nil { owners[family.root.identity] = family.familyKey }
        }
        return owners
    }

    private mutating func readBattery(uiVisible: Bool, now: Date) {
        guard let batterySource else { return }
        let interval = uiVisible ? Self.batteryInterval.visible : Self.batteryInterval.hidden
        if let battery, abs(now.timeIntervalSince(battery.readAt)) < interval { return }
        let reading = batterySource.read(now: now)
        battery = reading
        powerState = reading.powerState(after: powerState)
        loadAverager.add(reading.systemLoadAccumulator, at: now, discharging: reading.isDischarging)
        guard let draw = reading.drawWatts, draw.isFinite, draw > 0 else { return }
        if let previous = smoothedDraw, previous.discharging == reading.isDischarging,
           now > previous.at, now.timeIntervalSince(previous.at) < 10 * Self.drawTimeConstant {
            let alpha = 1 - exp(-now.timeIntervalSince(previous.at) / Self.drawTimeConstant)
            smoothedDraw = (previous.watts + alpha * (draw - previous.watts), now, reading.isDischarging)
        } else {
            // A new power source or a long gap starts the average afresh.
            smoothedDraw = (draw, now, reading.isDischarging)
        }
    }

    private mutating func readAssertions(uiVisible: Bool, now: Date) {
        guard let assertionSource else { return }
        let interval = uiVisible ? Self.assertionInterval.visible : Self.assertionInterval.hidden
        if let assertionsReadAt, abs(now.timeIntervalSince(assertionsReadAt)) < interval { return }
        assertionsReadAt = now
        // A failed read keeps the last list rather than claiming nothing is held.
        if let read = assertionSource.read() { assertions = read }
    }

    private func outlook(now: Date) -> BatteryOutlook? {
        guard let battery, battery.hasBattery || battery.systemLoadWatts != nil else { return nil }
        let snapshotDraw = smoothedDraw.flatMap { $0.discharging == battery.isDischarging ? $0.watts : nil }
        let draw = loadAverager.watts(over: Self.drawWindow, now: now) ?? snapshotDraw
        let remaining = battery.remainingWattHours
        let minutes: Double? = if battery.isDischarging, let remaining, let draw, draw > 0.5 {
            remaining / draw * 60
        } else { nil }
        return BatteryOutlook(
            chargePercent: battery.hasBattery ? battery.chargePercent : nil,
            isDischarging: battery.isDischarging,
            isCharging: battery.isCharging,
            drawWatts: draw,
            remainingWattHours: battery.hasBattery ? remaining : nil,
            minutesRemaining: minutes,
            healthPercent: battery.hasBattery ? battery.healthPercent : nil,
            cycleCount: battery.hasBattery ? battery.cycleCount : nil,
            adapterInputWatts: battery.onExternalPower ? battery.adapterInputWatts : nil,
            powerState: powerState,
            adapterRatedWatts: battery.onExternalPower ? battery.adapterRatedWatts : nil,
            averageDrawWatts: loadAverager.watts(over: Self.averageWindow, now: now)
        )
    }
}
