import Foundation

/// The process in a group that wakes the processor most.
public struct WakeupLeader: Equatable, Sendable {
    public let name: String
    /// Averaged over about five minutes.
    public let perSecond: Double
}

/// An app, command-line job or known macOS source and the energy it used.
public struct EnergyConsumer: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: ThermalWorkloadKind
    public let applicationPath: String?
    /// The terminal a command-line job runs in.
    public let hostAppName: String?
    /// The radar family to open or stop; nil for processes no family owns.
    public let familyKey: String?
    public let isSystem: Bool
    /// Processes running now; zero once the group has exited.
    public let processCount: Int
    /// Energy over the last scan's interval.
    public let wattsNow: Double
    /// Average over the last five minutes.
    public let averageWatts: Double
    public let lastHourWattHours: Double
    /// Five-minute averages.
    public let wakeupsPerSecond: Double
    public let diskWriteBytesPerSecond: Double
    public let lastHourDiskBytesWritten: Double
    /// Share of all measured process energy over the last five minutes, 0–1.
    public let shareOfMeasured: Double
    /// Extra battery time if this stopped, while on battery; nil otherwise.
    public let batteryMinutesGained: Double?
    /// Seconds the group was observed in the last five minutes.
    public let observedSeconds: TimeInterval
    /// Average cores busy over the last five minutes; 1.0 is one core.
    public let averageCores: Double
    public let tenMinuteDiskWriteBytesPerSecond: Double
    public let tenMinuteObservedSeconds: TimeInterval
    /// The member waking the processor most, averaged over about five minutes.
    public let busiestWakeups: WakeupLeader?

    public var isRunning: Bool { processCount > 0 }
    public var knownSource: ThermalKnownSource? {
        if case .knownSource(let source) = kind { return source }
        return nil
    }
    public var canInspectFamily: Bool { familyKey != nil }
}

/// Something keeping the Mac (or its display) from sleeping.
public struct SleepBlocker: Identifiable, Equatable, Sendable {
    public let id: String
    /// The app or job behind the assertion, such as "Safari" for audio coreaudiod holds for it.
    public let displayName: String
    /// The process that holds the assertion, when it differs from the one it serves.
    public let viaProcessName: String?
    public let pid: Int32
    public let consumerID: String?
    public let familyKey: String?
    public let effect: SleepAssertionEffect
    /// Plain words for why, such as "An audio stream is open".
    public let reason: String
    /// The holder's own description, verbatim.
    public let rawName: String
    public let heldSince: Date?
    public let isSystem: Bool
    /// Keep-awake utilities, such as Amphetamine, that are meant to do this.
    public let isIntentional: Bool
    /// The group used almost no CPU over the last ten minutes.
    public let isIdle: Bool

    public func heldFor(at now: Date) -> TimeInterval? {
        heldSince.map { max(0, now.timeIntervalSince($0)) }
    }
}

public enum EnergyFindingKind: String, Equatable, Sendable {
    /// Idle work holding a sleep assertion for a long time.
    case keepsMacAwake
    /// Frequent wake-ups of an idle processor.
    case wakeups
    /// Sustained heavy disk writes.
    case heavyDiskWrites
    /// On battery, a large share of the Mac's draw for ten minutes or more.
    case batteryDrain
}

public enum EnergyFindingSeverity: Int, Comparable, Equatable, Sendable {
    case notable = 1
    case attention = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One energy problem, told like every other finding: what, the evidence, one next step.
public struct EnergyFinding: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: EnergyFindingKind
    public let severity: EnergyFindingSeverity
    public let consumerID: String
    public let displayName: String
    public let familyKey: String?
    public let headline: String
    public let detail: String
    public let advice: String
    /// When the condition was first seen this session.
    public let since: Date
}

/// A radar family's energy, averaged over about a minute, for its page.
public struct FamilyPowerFigures: Equatable, Sendable {
    public var watts: Double
    public var wakeupsPerSecond: Double
    public var diskWriteBytesPerSecond: Double
    /// Sleep assertions its processes hold, directly or through macOS.
    public var keepsAwake: SleepAssertionEffect?
    var updatedAt: Date
}

/// The battery and what the Mac draws, smoothed so the numbers hold still.
public struct BatteryOutlook: Equatable, Sendable {
    public let chargePercent: Double?
    public let isDischarging: Bool
    /// The IsCharging flag as macOS reports it; the header goes by `powerState`.
    public let isCharging: Bool
    /// The whole Mac's draw, display and GPU included, averaged over about a minute.
    public let drawWatts: Double?
    public let remainingWattHours: Double?
    /// At the current draw; nil unless discharging.
    public let minutesRemaining: Double?
    public let healthPercent: Double?
    public let cycleCount: Int?
    /// What the wall delivers right now, including what goes into the battery.
    public let adapterInputWatts: Double?
    /// What the battery is really doing, from the direction of its current; nil without a battery.
    public var powerState: PowerState? = nil
    /// The charger's rating, while one is connected. Unlike its live input it does not move with load.
    public var adapterRatedWatts: Double? = nil
}

/// Everything the Energy page and the popover show, prepared off the main actor.
public struct EnergyReport: Equatable, Sendable {
    public let generatedAt: Date
    /// False on Macs whose kernel does not account energy per process; the
    /// page then ranks by wake-ups and disk writes only.
    public let perProcessEnergy: Bool
    public let battery: BatteryOutlook?
    /// All measured process energy over the last five minutes.
    public let measuredWatts: Double
    public let lastHourWattHours: Double
    /// Heaviest first; running groups before exited ones.
    public let consumers: [EnergyConsumer]
    public let blockers: [SleepBlocker]
    public let findings: [EnergyFinding]
    /// Measured process energy per minute, oldest first, for a sparkline.
    public let minuteWatts: [Double]
    public let measuredProcessCount: Int
    public let unmeasuredProcessCount: Int
    /// Per radar family, by family key.
    public let families: [String: FamilyPowerFigures]
    /// Today's heaviest apps and the last week's daily totals, kept across restarts.
    public let today: EnergyToday

    public static let empty = EnergyReport(
        generatedAt: .distantPast, perProcessEnergy: false, battery: nil, measuredWatts: 0, lastHourWattHours: 0,
        consumers: [], blockers: [], findings: [], minuteWatts: [], measuredProcessCount: 0, unmeasuredProcessCount: 0,
        families: [:])

    public init(
        generatedAt: Date, perProcessEnergy: Bool, battery: BatteryOutlook?, measuredWatts: Double,
        lastHourWattHours: Double, consumers: [EnergyConsumer], blockers: [SleepBlocker], findings: [EnergyFinding],
        minuteWatts: [Double], measuredProcessCount: Int, unmeasuredProcessCount: Int,
        families: [String: FamilyPowerFigures] = [:],
        today: EnergyToday = .empty
    ) {
        self.generatedAt = generatedAt
        self.perProcessEnergy = perProcessEnergy
        self.battery = battery
        self.measuredWatts = measuredWatts
        self.lastHourWattHours = lastHourWattHours
        self.consumers = consumers
        self.blockers = blockers
        self.findings = findings
        self.minuteWatts = minuteWatts
        self.measuredProcessCount = measuredProcessCount
        self.unmeasuredProcessCount = unmeasuredProcessCount
        self.families = families
        self.today = today
    }

    public func consumer(id: String) -> EnergyConsumer? {
        consumers.first { $0.id == id }
    }

    /// The Mac's whole draw, the figure the header compares the apps against.
    public var macWatts: Double? { battery?.drawWatts }

    /// The finding the Overview and popover lead with.
    public var topFinding: EnergyFinding? { findings.first }

    /// Sleep blockers worth showing by default: not macOS's own, and not intentional.
    public var unexpectedBlockers: [SleepBlocker] {
        blockers.filter { !$0.isSystem && !$0.isIntentional }
    }
}
