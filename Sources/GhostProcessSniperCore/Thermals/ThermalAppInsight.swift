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
        // A modest GPU leader must not conceal a saturated CPU core lower in the list.
        let active = rows.filter { $0.isSubstantial(at: now) }.max {
            ($0.observedActivity(at: now) ?? 0) < ($1.observedActivity(at: now) ?? 0)
        }
        let recent = heatNeedsReview ? activity.recentContributors.first(where: {
            $0.lastActiveAt < activity.sampledAt && (0...ThermalActivityHistory.maximumAge)
                .contains(now.timeIntervalSince($0.lastActiveAt))
        }) : nil
        if active == nil, let recent {
            let seconds = Int(max(0, now.timeIntervalSince(recent.lastActiveAt)).rounded())
            let span = recent.activeSpanSeconds
            let strength: EvidenceStrength = recent.activeSampleCount >= 3 && span >= 20 ? .repeated : .singleSample
            let resource = recent.peakCPUCapacityPercent >= recent.peakGPUPercent
                ? "up to \(ThermalActivityFormat.percent(recent.peakCPUCapacityPercent)) of total CPU capacity"
                : "up to \(ThermalActivityFormat.percent(recent.peakGPUPercent)) reported GPU activity"
            return Self(kind: .recent, evidenceStrength: strength,
                title: "Recently active: \(recent.displayName)",
                evidence: "\(recent.displayName) used \(resource) \(seconds)s ago, across \(recent.activeSampleCount) sampled \(recent.activeSampleCount == 1 ? "reading" : "readings"). Current work is lower or unmeasured. Temperature can lag activity.",
                action: recent.isSystemProcess
                    ? "Review related apps and optional work, then compare fresh readings as the Mac cools."
                    : "Check whether that work was expected, then compare fresh activity and temperature readings over the next minute.",
                badge: "Recent workload, cause unconfirmed",
                contributor: rows.first { $0.id == recent.id })
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
        let history = activity.recentContributors.first { $0.id == leader.id }
        let sustained = history.map { $0.activeSampleCount >= 3 && $0.activeSpanSeconds >= 20 } ?? false
        return Self(kind: .active,
            evidenceStrength: sustained ? .repeated : .singleSample,
            title: heatNeedsReview ? "Start with \(leader.displayName)" : "Most active: \(leader.displayName)",
            evidence: "\(resource) Based on \(leader.processCount) sampled \(leader.processCount == 1 ? "process" : "processes"). \(sustained ? "Repeated across recent scans." : "One current reading; the cause of heat is unconfirmed.")",
            action: leader.suggestedAction(at: now),
            badge: sustained ? "Repeated workload observed" : "Current workload observed", contributor: leader)
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
