import Foundation

/// Keeps a short history of sampled work so a recently quiet app does not vanish
/// from the explanation before hardware temperature has had time to respond.
/// Chip temperature integrates power over roughly a minute, so contributors are
/// ranked by decayed accumulated load: a long compile that just ended outranks a
/// one-reading blip that happened a moment later.
public struct ThermalActivityHistory: Sendable {
    public static let maximumAge: TimeInterval = 180
    static let loadTimeConstant: TimeInterval = 60
    private static let maximumSamples = 720
    /// One reading stands for at most this long, so a stalled sampler cannot turn a
    /// single value into minutes of load.
    private static let maximumStep: TimeInterval = 15
    /// Without an earlier reading the cadence is unknown; assume a short one so a
    /// first sample stays light.
    private static let firstStep: TimeInterval = 1
    private static let minimumActivity = 5.0
    private static let minimumLoad = 1.0

    private struct Activity: Sendable {
        let id: String
        let displayName: String
        let familyKey: String
        let cpuCapacityPercent: Double
        let gpuPercent: Double
        let activity: Double
        let isSystemProcess: Bool
    }

    private struct Reading: Sendable {
        let date: Date
        let active: [Activity]
    }

    private struct Load: Sendable {
        var ewma: Double
        var lastMeasuredAt: Date

        func value(at now: Date) -> Double {
            ewma * exp(-max(0, now.timeIntervalSince(lastMeasuredAt)) / ThermalActivityHistory.loadTimeConstant)
        }
    }

    private var readings: [Reading] = []
    private var loads: [String: Load] = [:]
    /// Loads as they were before the latest reading, so a re-published sample replaces
    /// its own contribution instead of counting twice.
    private var loadsBeforeLatest: [String: Load] = [:]

    public init() {}

    /// Only a new process sample adds evidence. Re-publishing the same sample
    /// replaces it, and an older sample cannot rewind the window.
    public mutating func record(_ summary: ThermalActivitySummary, at now: Date) -> ThermalActivitySummary {
        let age = now.timeIntervalSince(summary.sampledAt)
        guard age.isFinite, (0...ThermalActivitySummary.maximumAge).contains(age) else { return summary }
        let date = summary.sampledAt
        let active = summary.measuredContributorsForHistory.compactMap { contributor -> Activity? in
            guard let activity = contributor.observedActivity(at: date),
                  activity >= Self.minimumActivity || contributor.isSubstantial(at: date) else { return nil }
            return Activity(id: contributor.id, displayName: contributor.displayName, familyKey: contributor.familyKey,
                            cpuCapacityPercent: contributor.cpuCapacityPercent(at: date) ?? 0,
                            gpuPercent: contributor.gpuActivityPercent(at: date) ?? 0,
                            activity: activity, isSystemProcess: contributor.isSystemProcess)
        }
        let reading = Reading(date: date, active: active)
        let previousDate: Date?
        if let last = readings.last {
            guard reading.date >= last.date else { return summary }
            if reading.date == last.date {
                readings[readings.count - 1] = reading
                loads = loadsBeforeLatest
                previousDate = readings.count > 1 ? readings[readings.count - 2].date : nil
            } else {
                readings.append(reading)
                loadsBeforeLatest = loads
                previousDate = last.date
            }
        } else {
            readings.append(reading)
            loadsBeforeLatest = loads
            previousDate = nil
        }
        readings.removeAll { reading.date.timeIntervalSince($0.date) > Self.maximumAge }
        if readings.count > Self.maximumSamples {
            readings.removeFirst(readings.count - Self.maximumSamples)
        }
        updateLoads(with: active, at: date, previousDate: previousDate)

        var recent: [String: ThermalRecentContributor] = [:]
        for item in readings {
            for contributor in item.active {
                let load = loads[contributor.id]?.value(at: date) ?? 0
                if let previous = recent[contributor.id] {
                    recent[contributor.id] = ThermalRecentContributor(
                        id: contributor.id, displayName: contributor.displayName,
                        familyKey: contributor.familyKey,
                        peakCPUCapacityPercent: max(previous.peakCPUCapacityPercent, contributor.cpuCapacityPercent),
                        peakGPUPercent: max(previous.peakGPUPercent, contributor.gpuPercent),
                        firstActiveAt: previous.firstActiveAt, lastActiveAt: item.date,
                        activeSampleCount: previous.activeSampleCount + 1,
                        isSystemProcess: previous.isSystemProcess && contributor.isSystemProcess,
                        sustainedLoadPercent: load, sustainedLoadAt: date)
                } else {
                    recent[contributor.id] = ThermalRecentContributor(
                        id: contributor.id, displayName: contributor.displayName,
                        familyKey: contributor.familyKey,
                        peakCPUCapacityPercent: contributor.cpuCapacityPercent,
                        peakGPUPercent: contributor.gpuPercent,
                        firstActiveAt: item.date, lastActiveAt: item.date,
                        activeSampleCount: 1, isSystemProcess: contributor.isSystemProcess,
                        sustainedLoadPercent: load, sustainedLoadAt: date)
                }
            }
        }
        let ordered = recent.values.sorted {
            if $0.sustainedLoadPercent != $1.sustainedLoadPercent { return $0.sustainedLoadPercent > $1.sustainedLoadPercent }
            if $0.lastActiveAt != $1.lastActiveAt { return $0.lastActiveAt > $1.lastActiveAt }
            let left = max($0.peakCPUCapacityPercent, $0.peakGPUPercent)
            let right = max($1.peakCPUCapacityPercent, $1.peakGPUPercent)
            return left == right ? $0.id < $1.id : left > right
        }
        let span = readings.first.map { max(0, reading.date.timeIntervalSince($0.date)) } ?? 0
        return summary.includingHistory(ordered, sampleCount: readings.count, spanSeconds: span)
    }

    /// An exponentially weighted average with a one-minute time constant. Each reading
    /// covers the time since that contributor's last measurement (at most 15 s), so the
    /// result does not depend on the refresh cadence. A contributor missing from a
    /// reading keeps its average, which only decays with time.
    private mutating func updateLoads(with active: [Activity], at date: Date, previousDate: Date?) {
        let firstStep = previousDate.map { min(Self.maximumStep, max(0, date.timeIntervalSince($0))) } ?? Self.firstStep
        for item in active {
            if var load = loads[item.id] {
                let gap = max(0, date.timeIntervalSince(load.lastMeasuredAt))
                let weight = 1 - exp(-min(Self.maximumStep, gap) / Self.loadTimeConstant)
                load.ewma = load.ewma * exp(-gap / Self.loadTimeConstant) + item.activity * weight
                load.lastMeasuredAt = date
                loads[item.id] = load
            } else {
                loads[item.id] = Load(ewma: item.activity * (1 - exp(-firstStep / Self.loadTimeConstant)),
                                      lastMeasuredAt: date)
            }
        }
        loads = loads.filter { _, load in
            load.lastMeasuredAt == date ||
                (date.timeIntervalSince(load.lastMeasuredAt) <= Self.maximumAge && load.value(at: date) >= Self.minimumLoad)
        }
    }

    /// Projects a raw sample and records it; callers without a refresh worker use this.
    mutating func recordProjection(of processes: [ProcessMetrics], families: [ProcessFamily],
                                   at now: Date) -> ThermalActivitySummary {
        record(ThermalActivityAnalyzer.project(processes: processes, families: families, now: now), at: now)
    }
}
