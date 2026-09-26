import Foundation

/// Keeps a short history of sampled work so a recently quiet app does not vanish
/// from the explanation before hardware temperature has had time to respond.
public struct ThermalActivityHistory: Sendable {
    public static let maximumAge: TimeInterval = 180
    private static let maximumSamples = 720

    private struct Activity: Sendable {
        let id: String
        let displayName: String
        let familyKey: String
        let cpuCapacityPercent: Double
        let gpuPercent: Double
        let isSystemProcess: Bool
    }

    private struct Reading: Sendable {
        let date: Date
        let active: [Activity]
    }

    private var readings: [Reading] = []

    public init() {}

    /// Only a new process sample adds evidence. Re-publishing the same sample
    /// replaces it, and an older sample cannot rewind the window.
    public mutating func record(_ summary: ThermalActivitySummary, at now: Date) -> ThermalActivitySummary {
        let age = now.timeIntervalSince(summary.sampledAt)
        guard age.isFinite, (0...ThermalActivitySummary.maximumAge).contains(age) else { return summary }
        let active = summary.contributors.filter(\.isSubstantial).map {
            Activity(id: $0.id, displayName: $0.displayName, familyKey: $0.familyKey,
                     cpuCapacityPercent: $0.cpuCapacityPercent, gpuPercent: $0.gpuPercent,
                     isSystemProcess: $0.isSystemProcess)
        }
        let reading = Reading(date: summary.sampledAt, active: active)
        if let last = readings.last {
            guard reading.date >= last.date else { return summary }
            if reading.date == last.date {
                readings[readings.count - 1] = reading
            } else {
                readings.append(reading)
            }
        } else {
            readings.append(reading)
        }
        readings.removeAll { reading.date.timeIntervalSince($0.date) > Self.maximumAge }
        if readings.count > Self.maximumSamples {
            readings.removeFirst(readings.count - Self.maximumSamples)
        }

        var recent: [String: ThermalRecentContributor] = [:]
        for item in readings {
            for contributor in item.active {
                if let previous = recent[contributor.id] {
                    recent[contributor.id] = ThermalRecentContributor(
                        id: contributor.id, displayName: contributor.displayName,
                        familyKey: contributor.familyKey,
                        peakCPUCapacityPercent: max(previous.peakCPUCapacityPercent, contributor.cpuCapacityPercent),
                        peakGPUPercent: max(previous.peakGPUPercent, contributor.gpuPercent),
                        firstActiveAt: previous.firstActiveAt, lastActiveAt: item.date,
                        activeSampleCount: previous.activeSampleCount + 1,
                        isSystemProcess: previous.isSystemProcess && contributor.isSystemProcess)
                } else {
                    recent[contributor.id] = ThermalRecentContributor(
                        id: contributor.id, displayName: contributor.displayName,
                        familyKey: contributor.familyKey,
                        peakCPUCapacityPercent: contributor.cpuCapacityPercent,
                        peakGPUPercent: contributor.gpuPercent,
                        firstActiveAt: item.date, lastActiveAt: item.date,
                        activeSampleCount: 1, isSystemProcess: contributor.isSystemProcess)
                }
            }
        }
        let ordered = recent.values.sorted {
            if $0.lastActiveAt != $1.lastActiveAt { return $0.lastActiveAt > $1.lastActiveAt }
            let left = max($0.peakCPUCapacityPercent, $0.peakGPUPercent)
            let right = max($1.peakCPUCapacityPercent, $1.peakGPUPercent)
            return left == right ? $0.id < $1.id : left > right
        }
        let span = readings.first.map { max(0, reading.date.timeIntervalSince($0.date)) } ?? 0
        return summary.includingHistory(ordered, sampleCount: readings.count, spanSeconds: span)
    }

    /// Projects a raw sample and records it; callers without a refresh worker use this.
    mutating func recordProjection(of processes: [ProcessMetrics], families: [ProcessFamily],
                                   at now: Date) -> ThermalActivitySummary {
        record(ThermalActivityAnalyzer.project(processes: processes, families: families, now: now), at: now)
    }
}
