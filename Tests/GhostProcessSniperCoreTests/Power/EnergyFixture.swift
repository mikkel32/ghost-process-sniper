import Foundation
@testable import GhostProcessSniperCore

/// Processes with scripted lifetime energy, wake-up and disk counters, and
/// scripted batteries and power assertions, for driving `EnergyMonitor` tick
/// by tick.
enum EnergyFixture {
    static let start = Date(timeIntervalSince1970: 2_000_000)

    struct Counters {
        var joules = 0.0
        var wakeups: UInt64 = 0
        var diskBytes: UInt64 = 0
        var cpuSeconds = 0.0
    }

    static func process(
        pid: Int32, name: String, path: String, parent: Int32 = 1, command: String? = nil,
        counters: Counters, cpu: Double = 0, at date: Date, watts: Double? = 0, isSystem: Bool = false
    ) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0),
            parentPID: parent, userID: 501, ownerName: "dev", name: name, executablePath: path,
            commandLine: command ?? name, residentMemoryBytes: 50 << 20, physicalFootprintBytes: 50 << 20,
            virtualMemoryBytes: 100 << 20, cpuPercent: cpu, totalProcessorSeconds: counters.cpuSeconds,
            threadCount: 4, isSystemProcess: isSystem, sampledAt: date,
            power: ProcessPowerUsage(
                lifetimeEnergyNanojoules: UInt64(counters.joules * 1_000_000_000),
                lifetimeIdleWakeups: counters.wakeups, lifetimeDiskBytesWritten: counters.diskBytes,
                watts: watts, measuredAt: date)
        )
    }

    static func family(_ members: [ProcessMetrics], kind: DevProcessKind? = nil) -> ProcessFamily {
        let family = RefreshPerformanceFixture.family(members[0], members: members)
        guard let kind else { return family }
        return family.enriched(classification: DevClassification(kind: kind, confidence: 0.9, reason: "fixture"))
    }
}

final class ScriptedBattery: BatterySource, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: BatteryReading
    private(set) var reads = 0

    init(_ reading: BatteryReading) { self.reading = reading }

    func set(_ change: (inout BatteryReading) -> Void) { lock.withLock { change(&reading) } }

    func read(now: Date) -> BatteryReading {
        lock.withLock {
            reads += 1
            var copy = reading
            copy.readAt = now
            return copy
        }
    }

    /// 60 Wh left at 12.5 V, discharging at `watts`.
    static func discharging(watts: Double) -> ScriptedBattery {
        ScriptedBattery(BatteryReading(
            hasBattery: true, onExternalPower: false, isCharging: false, chargePercent: 80,
            currentCapacityMilliampHours: 4_800, fullChargeCapacityMilliampHours: 6_000,
            designCapacityMilliampHours: 6_000, voltageMillivolts: 12_500,
            amperageMilliamps: -watts / 12.5 * 1_000, batteryDischargeWatts: watts, cycleCount: 300,
            readAt: .distantPast))
    }
}

final class ScriptedAssertions: SleepAssertionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var assertions: [SleepAssertion]

    init(_ assertions: [SleepAssertion] = []) { self.assertions = assertions }

    func set(_ assertions: [SleepAssertion]) { lock.withLock { self.assertions = assertions } }

    func read() -> [SleepAssertion]? { lock.withLock { assertions } }
}

/// Drives an `EnergyMonitor` over scripted ticks.
struct EnergyDriver {
    var monitor: EnergyMonitor
    var now = EnergyFixture.start
    let tick: TimeInterval

    init(battery: ScriptedBattery? = nil, assertions: ScriptedAssertions? = nil, tick: TimeInterval = 5) {
        monitor = EnergyMonitor(battery: battery, assertions: assertions)
        self.tick = tick
    }

    /// Runs `ticks` scans; `processes` builds the table for each tick index.
    @discardableResult
    mutating func run(ticks: Int, visible: Bool = true, families: ([ProcessMetrics]) -> [ProcessFamily] = { _ in [] },
                      processes: (Int, Date) -> [ProcessMetrics]) -> EnergyReport {
        var report = EnergyReport.empty
        for index in 0..<ticks {
            let table = processes(index, now)
            report = monitor.update(processes: table, families: families(table), responsiblePIDs: [:],
                                    uiVisible: visible, now: now)
            now = now.addingTimeInterval(tick)
        }
        return report
    }
}
