import Foundation

/// Energy, wake-ups, writes and CPU an app or job used over some span.
public struct EnergyUsage: Equatable, Sendable {
    /// The app's path, "known:<source>", or "name:<command>" for a job, so the
    /// same work adds up across runs and restarts.
    public let key: String
    public var displayName: String
    public var applicationPath: String?
    public var joules: Double
    public var wakeups: Double
    public var diskBytesWritten: Double
    public var cpuSeconds: Double

    public init(key: String, displayName: String, applicationPath: String?, joules: Double = 0, wakeups: Double = 0,
                diskBytesWritten: Double = 0, cpuSeconds: Double = 0) {
        self.key = key
        self.displayName = displayName
        self.applicationPath = applicationPath
        self.joules = joules
        self.wakeups = wakeups
        self.diskBytesWritten = diskBytesWritten
        self.cpuSeconds = cpuSeconds
    }

    public var wattHours: Double { joules / 3_600 }

    mutating func add(_ other: EnergyUsage) {
        displayName = other.displayName
        applicationPath = other.applicationPath ?? applicationPath
        joules += other.joules
        wakeups += other.wakeups
        diskBytesWritten += other.diskBytesWritten
        cpuSeconds += other.cpuSeconds
    }
}

public struct EnergyDayUsage: Equatable, Sendable {
    /// The local day, "2026-09-27".
    public let day: String
    public let usage: EnergyUsage
}

public struct EnergyDayTotal: Equatable, Sendable {
    public let day: String
    public let wattHours: Double
}

/// Today's heaviest apps and jobs, and each recent day's total.
public struct EnergyToday: Equatable, Sendable {
    public let entries: [EnergyUsage]
    public let wattHours: Double
    /// Today's measured energy against a full charge, when there is a battery.
    public let fullChargeWattHours: Double?
    /// The last seven days that have any energy, oldest first, today last.
    public let days: [EnergyDayTotal]

    public static let empty = EnergyToday(entries: [], wattHours: 0, fullChargeWattHours: nil, days: [])

    /// "about 60% of a full charge".
    public var shareOfFullCharge: Double? {
        fullChargeWattHours.flatMap { $0 > 0 ? wattHours / $0 : nil }
    }
}

enum EnergyHistory {
    static let entryLimit = 10
    static let dayCount = 7

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 0, day = parts.day ?? 0
        return "\(year)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }

    /// Jobs get a new identity every run; their command name is what repeats.
    static func key(for assignment: EnergyGroupAssignment) -> String {
        if let path = assignment.applicationPath { return path }
        if case .knownSource(let source) = assignment.kind { return "known:\(source.rawValue)" }
        return "name:\(assignment.displayName)"
    }
}

/// Accumulates each scan's charges into today's totals in memory and hands
/// the store what it has not written yet, every five minutes. Today's rows
/// are loaded once at launch, so a restart continues the day.
struct EnergyHistoryTracker: Sendable {
    static let flushInterval: TimeInterval = 300
    static let loadRetryInterval: TimeInterval = 300

    /// Without a store there is nothing to load or write; totals stay in memory.
    let persists: Bool
    private(set) var isLoaded: Bool
    private var loadAttemptedAt: Date?
    private var day: String?
    private var today: [String: EnergyUsage] = [:]
    private var earlier: [String: Double] = [:]
    private var pending: [String: [String: EnergyUsage]] = [:]
    private var lastFlush: Date?

    init(persists: Bool = true) {
        self.persists = persists
        isLoaded = !persists
    }

    func needsLoad(now: Date) -> Bool {
        !isLoaded && (loadAttemptedAt.map { now.timeIntervalSince($0) >= Self.loadRetryInterval } ?? true)
    }

    mutating func noteLoadFailed(now: Date) { loadAttemptedAt = now }

    /// Stored rows join what this session measured before they arrived.
    mutating func load(_ rows: [EnergyDayUsage], now: Date) {
        let current = EnergyHistory.dayKey(for: now)
        rollOver(to: current)
        for row in rows {
            if row.day == current {
                today[row.usage.key, default: EnergyUsage(key: row.usage.key, displayName: row.usage.displayName,
                                                          applicationPath: row.usage.applicationPath)].add(row.usage)
            } else {
                earlier[row.day, default: 0] += row.usage.joules
            }
        }
        isLoaded = true
    }

    mutating func record(_ charges: [(EnergyGroupAssignment, EnergyMinute)], now: Date) {
        let current = EnergyHistory.dayKey(for: now)
        rollOver(to: current)
        for (assignment, charge) in charges where charge.joules > 0 || charge.wakeups > 0 || charge.diskBytesWritten > 0 {
            let key = EnergyHistory.key(for: assignment)
            let usage = EnergyUsage(key: key, displayName: assignment.displayName,
                                    applicationPath: assignment.applicationPath, joules: charge.joules,
                                    wakeups: charge.wakeups, diskBytesWritten: charge.diskBytesWritten,
                                    cpuSeconds: charge.cpuSeconds)
            today[key, default: EnergyUsage(key: key, displayName: usage.displayName,
                                            applicationPath: usage.applicationPath)].add(usage)
            guard persists else { continue }
            pending[current, default: [:]][key, default: EnergyUsage(key: key, displayName: usage.displayName,
                                                                     applicationPath: usage.applicationPath)].add(usage)
        }
    }

    /// What to write now, by day; nil until the store's rows were loaded and
    /// five minutes have passed since the last write.
    mutating func takeFlush(now: Date, force: Bool = false) -> [(day: String, usages: [EnergyUsage])]? {
        guard isLoaded, !pending.isEmpty else { return nil }
        let first = lastFlush ?? now
        lastFlush = first
        guard force || now.timeIntervalSince(first) >= Self.flushInterval || now < first else { return nil }
        lastFlush = now
        let batches = pending.keys.sorted().map { day in
            (day: day, usages: pending[day, default: [:]].values.sorted { $0.key < $1.key })
        }
        pending = [:]
        return batches
    }

    /// A write that failed goes back in the queue for the next attempt.
    mutating func restore(_ batches: [(day: String, usages: [EnergyUsage])]) {
        for batch in batches {
            for usage in batch.usages {
                pending[batch.day, default: [:]][usage.key, default: EnergyUsage(
                    key: usage.key, displayName: usage.displayName, applicationPath: usage.applicationPath)].add(usage)
            }
        }
    }

    func summary(fullChargeWattHours: Double?, now: Date) -> EnergyToday {
        let entries = today.values.sorted { $0.joules == $1.joules ? $0.key < $1.key : $0.joules > $1.joules }
        let total = today.values.reduce(0) { $0 + $1.joules }
        var days = earlier.filter { $0.value > 0 }.map { EnergyDayTotal(day: $0.key, wattHours: $0.value / 3_600) }
        days.sort { $0.day < $1.day }
        days = Array(days.suffix(EnergyHistory.dayCount - 1))
        days.append(EnergyDayTotal(day: day ?? EnergyHistory.dayKey(for: now), wattHours: total / 3_600))
        return EnergyToday(entries: Array(entries.prefix(EnergyHistory.entryLimit)), wattHours: total / 3_600,
                           fullChargeWattHours: fullChargeWattHours, days: days)
    }

    private mutating func rollOver(to current: String) {
        guard day != current else { return }
        if let day {
            earlier[day, default: 0] += today.values.reduce(0) { $0 + $1.joules }
        }
        today = [:]
        day = current
        // Keep a week of daily totals; older days stay in the store.
        if earlier.count > EnergyHistory.dayCount {
            for stale in earlier.keys.sorted().dropLast(EnergyHistory.dayCount) { earlier[stale] = nil }
        }
    }
}
