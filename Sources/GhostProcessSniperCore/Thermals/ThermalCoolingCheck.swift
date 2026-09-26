import Foundation

/// A user-started comparison; it never pauses work or infers causality from a drop.
public struct ThermalCoolingCheck: Equatable, Sendable {
    public struct Result: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let note: String
    }
    private let contributor: ThermalContributor
    private let snapshot: ThermalSnapshot
    private let startedAt: Date

    public init(contributor: ThermalContributor, snapshot: ThermalSnapshot, at now: Date) {
        self.contributor = contributor
        self.snapshot = snapshot
        startedAt = now
    }

    public func evaluate(activity: ThermalActivitySummary, snapshot current: ThermalSnapshot, at now: Date) -> Result {
        let note = "Observed changes are not proof of causation. Other workloads and cooling also affect temperature."
        guard (0...180).contains(now.timeIntervalSince(startedAt)) else {
            return Result(title: "Comparison expired", detail: "Start a new comparison with current readings.", note: note)
        }
        guard current.sampledAt.timeIntervalSince(startedAt) >= 15 else {
            return Result(title: "Baseline saved for \(contributor.displayName)",
                detail: "Pause optional work in the app yourself, then scan again after at least 15 seconds. No app was paused by this button.",
                note: "A temperature change can take longer to appear. Keep the work you need running.")
        }
        guard (0...15).contains(now.timeIntervalSince(current.sampledAt)),
              let app = activity.measuredContributor(id: contributor.id, at: now),
              app.measuredAt > contributor.measuredAt else {
            return Result(title: "Waiting for new app readings",
                detail: "\(contributor.displayName) is not currently measurable or has left the sample. Missing readings are not treated as zero.", note: note)
        }
        var changes: [String] = []
        if let beforeCPU = contributor.cpuCapacityPercent(at: startedAt),
           let afterCPU = app.cpuCapacityPercent(at: now),
           let baselineDate = contributor.cpuMeasuredAt, let currentDate = app.cpuMeasuredAt,
           currentDate > baselineDate {
            changes.append("App CPU capacity: \(ThermalActivityFormat.percent(beforeCPU)) to \(ThermalActivityFormat.percent(afterCPU))")
        }
        if let beforeGPU = contributor.gpuActivityPercent(at: startedAt),
           let afterGPU = app.gpuActivityPercent(at: now),
           let baselineDate = contributor.gpuMeasuredAt, let currentDate = app.gpuMeasuredAt,
           currentDate > baselineDate {
            changes.append("Reported GPU activity: \(ThermalActivityFormat.percent(beforeGPU)) to \(ThermalActivityFormat.percent(afterGPU))")
        }
        guard !changes.isEmpty else {
            return Result(title: "Waiting for new app readings",
                detail: "The same CPU or GPU metric was not measured in both scans. Missing readings are not treated as zero.", note: note)
        }
        let baselineFresh = (0...15).contains(startedAt.timeIntervalSince(snapshot.sampledAt))
        if baselineFresh {
            if let text = change(label: "CPU temperature", from: snapshot.cpuCelsius, to: current.cpuCelsius,
                                 firstKey: snapshot.cpuSensorKey, secondKey: current.cpuSensorKey) { changes.append(text) }
            if let text = change(label: "GPU temperature", from: snapshot.gpuCelsius, to: current.gpuCelsius,
                                 firstKey: snapshot.gpuSensorKey, secondKey: current.gpuSensorKey) { changes.append(text) }
        }
        return Result(title: "Reading comparison: \(app.displayName)", detail: changes.joined(separator: " · "), note: note)
    }

    private func change(label: String, from: Double?, to: Double?, firstKey: String?, secondKey: String?) -> String? {
        guard firstKey == secondKey else { return nil }
        guard let from = ThermalTemperatureAssessment.valid(from),
              let to = ThermalTemperatureAssessment.valid(to) else { return nil }
        let delta = to - from
        let value = abs(delta).formatted(.number.precision(.fractionLength(1)))
        return "\(label): \(delta < 0 ? "down" : delta > 0 ? "up" : "unchanged") \(value)°C"
    }
}
