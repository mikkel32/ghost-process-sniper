import Foundation

/// Explains observed workload, never a fabricated per-app temperature or heat share.
public struct ThermalAppInsight: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case checking, unexplained, modest, active, recent }
    /// Strength of workload evidence, never a probability that an app caused heat.
    public enum EvidenceStrength: Equatable, Sendable { case limited, singleSample, repeated }
    public let kind: Kind
    public let evidenceStrength: EvidenceStrength
    public let title: String
    public let evidence: String
    public let action: String
    public let badge: String
    public let contributor: ThermalContributor?

    public static func evaluate(activity: ThermalActivitySummary, diagnosis: ThermalDiagnosis,
                                at now: Date) -> Self {
        guard diagnosis.isActivityFresh else {
            return Self(kind: .checking, evidenceStrength: .limited, title: "Get a fresh activity reading",
                evidence: "The last app readings have expired or are not available yet.",
                action: "Scan now to see which apps are using resources.", badge: "Awaiting a sample", contributor: nil)
        }
        let rows = activity.visibleContributors(at: now)
        let heatNeedsReview = diagnosis.temperature.band.rawValue >= ThermalTemperatureBand.warm.rawValue ||
            diagnosis.state == .warm || diagnosis.state == .serious || diagnosis.state == .critical
        let history = activity.recentContributors
        func load(_ id: String) -> Double { history.first { $0.id == id }?.sustainedLoad(at: now) ?? 0 }
        // A modest GPU leader must not conceal a saturated CPU core lower in the list.
        let active = rows.filter { $0.isSubstantial(at: now) }.max {
            max($0.observedActivity(at: now) ?? 0, load($0.id)) < max($1.observedActivity(at: now) ?? 0, load($1.id))
        }
        // Temperature integrates power, so decayed accumulated load can outrank a lighter current reading.
        let sustained = heatNeedsReview ? history.filter { $0.sustainedLoad(at: now) >= substantialLoad }.max {
            $0.sustainedLoad(at: now) < $1.sustainedLoad(at: now)
        } : nil
        let activeScore = active.map { max($0.observedActivity(at: now) ?? 0, load($0.id)) } ?? -1
        if let sustained, sustained.sustainedLoad(at: now) > activeScore {
            return recent(sustained, rows: rows, at: now)
        }
        if active == nil, heatNeedsReview, let earlier = activity.earlierContributor(at: now) {
            return recent(earlier, rows: rows, at: now)
        }
        guard let leader = active ?? rows.max(by: {
            ($0.observedActivity(at: now) ?? 0) < ($1.observedActivity(at: now) ?? 0)
        }) else {
            return Self(kind: .unexplained,
                evidenceStrength: .limited,
                title: heatNeedsReview ? "No clear app contributor yet" : "No demanding app in this sample",
                evidence: activity.unavailableProcessCount > 0
                    ? "Some processes could not be measured. A busy app may be missing from this scan."
                    : "The measured processes show little activity right now. Temperature can take longer to settle.",
                action: heatNeedsReview ? "Check ventilation and recent demanding work, then compare another scan."
                    : "Keep working normally. Check again if your Mac continues to feel warm.",
                badge: "Limited evidence", contributor: nil)
        }
        let resource = resourceEvidence(for: leader, at: now)
        if !leader.isSubstantial(at: now) {
            return Self(kind: .modest, evidenceStrength: .limited, title: "\(leader.displayName) is busiest",
                evidence: "Activity is modest: \(resource)",
                action: heatNeedsReview
                    ? "This activity alone does not clearly explain the heat. Check recent demanding work and compare another scan."
                    : "No demanding workload stands out in this sample. Inspect the app for details or keep working normally.",
                badge: "Light workload observed", contributor: leader)
        }
        let repeated = history.first { $0.id == leader.id }
            .map { $0.activeSampleCount >= 3 && $0.activeSpanSeconds >= 20 } ?? false
        return Self(kind: .active,
            evidenceStrength: repeated ? .repeated : .singleSample,
            title: heatNeedsReview ? "Start with \(leader.displayName)" : "Most active: \(leader.displayName)",
            evidence: "\(resource) Based on \(leader.processCount) sampled \(leader.processCount == 1 ? "process" : "processes"). \(repeated ? "Repeated across recent scans." : "One current reading; the cause of heat is unconfirmed.")",
            action: leader.suggestedAction(at: now),
            badge: repeated ? "Repeated workload observed" : "Current workload observed", contributor: leader)
    }

    /// Matches the 10% of total CPU capacity that makes current activity substantial.
    private static let substantialLoad = 10.0

    private static func recent(_ entry: ThermalRecentContributor, rows: [ThermalContributor], at now: Date) -> Self {
        let current = rows.first { $0.id == entry.id }
        let seconds = Int(max(0, now.timeIntervalSince(entry.lastActiveAt)).rounded())
        let strength: EvidenceStrength = entry.activeSampleCount >= 3 && entry.activeSpanSeconds >= 20 ? .repeated : .singleSample
        let gpuLed = entry.peakGPUPercent > entry.peakCPUCapacityPercent
        let load = entry.sustainedLoad(at: now)
        let evidence: String
        if entry.activeSampleCount >= 2, load >= 1 {
            let minutes = min(3, max(1, Int((entry.activeSpanSeconds / 60).rounded(.up))))
            let resource = gpuLed ? "reported GPU activity" : "of CPU capacity"
            let timing = current == nil
                ? "Last busy \(seconds)s ago; current work is lower or unmeasured."
                : "Its current work is lower."
            evidence = "\(entry.displayName) averaged \(ThermalActivityFormat.percent(load)) \(resource) over the last \(minutes) min (recent readings weigh more). \(timing) Temperature can lag activity."
        } else {
            let resource = gpuLed
                ? "up to \(ThermalActivityFormat.percent(entry.peakGPUPercent)) reported GPU activity"
                : "up to \(ThermalActivityFormat.percent(entry.peakCPUCapacityPercent)) of total CPU capacity"
            evidence = "\(entry.displayName) used \(resource) \(seconds)s ago, across \(entry.activeSampleCount) sampled \(entry.activeSampleCount == 1 ? "reading" : "readings"). Current work is lower or unmeasured. Temperature can lag activity."
        }
        return Self(kind: .recent, evidenceStrength: strength,
            title: "Recently active: \(entry.displayName)",
            evidence: evidence,
            action: entry.isSystemProcess
                ? "Review related apps and optional work, then compare fresh readings as the Mac cools."
                : "Check whether that work was expected, then compare fresh activity and temperature readings over the next minute.",
            badge: "Recent workload, cause unconfirmed",
            contributor: current)
    }

    private static func resourceEvidence(for contributor: ThermalContributor, at now: Date) -> String {
        let cpu = contributor.cpuCapacityPercent(at: now) == nil
            ? "CPU activity is unmeasured"
            : "\(ThermalActivityFormat.percent(contributor.cpuCapacityPercent)) of total CPU capacity"
        let gpu = contributor.gpuActivityPercent(at: now) == nil
            ? "GPU activity is unreported"
            : "\(ThermalActivityFormat.percent(contributor.gpuPercent)) reported GPU activity"
        return "\(cpu); \(gpu)."
    }
}
