import Foundation

/// Activity describes an observed workload; neither coverage nor a zero GPU
/// counter proves that every source of heat was measured.
struct ThermalWorkloadAssessment {
    let isFresh: Bool
    let leader: ThermalContributor?
    let isSubstantial: Bool
    let hasPartialCoverage: Bool
    let recentLeader: ThermalRecentContributor?
    let recentSecondsAgo: Int?
    let coverageText: String

    init(activity: ThermalActivitySummary, at now: Date) {
        isFresh = (0...ThermalActivitySummary.maximumAge).contains(now.timeIntervalSince(activity.sampledAt))
        let visible = isFresh ? activity.visibleContributors(at: now) : []
        let current = visible.filter { $0.isSubstantial(at: now) }
        leader = (current.isEmpty ? visible : current).max {
            ($0.observedActivity(at: now) ?? 0) < ($1.observedActivity(at: now) ?? 0)
        }
        isSubstantial = !current.isEmpty
        hasPartialCoverage = !isFresh || activity.coverage != .processInventory ||
            activity.observedProcessCount == 0 || activity.unavailableProcessCount > 0 ||
            activity.cpuObservedProcessCount < activity.observedProcessCount ||
            visible.count != activity.contributors.count
        recentLeader = isFresh ? activity.recentContributors.first(where: {
            $0.lastActiveAt < activity.sampledAt &&
                (0...ThermalActivityHistory.maximumAge).contains(now.timeIntervalSince($0.lastActiveAt))
        }) : nil
        recentSecondsAgo = recentLeader.map { Int(max(0, now.timeIntervalSince($0.lastActiveAt)).rounded()) }
        let scope = activity.coverage == .processInventory ? "Process sample" : "Monitored families only"
        coverageText = isFresh
            ? "\(scope): CPU measured for \(activity.cpuObservedProcessCount) of \(activity.observedProcessCount) processes; GPU activity reported for \(activity.gpuObservedProcessCount). \(activity.unavailableProcessCount) without either reading."
            : "Process activity needs a fresh scan"
    }

    func nextStep(temperature: ThermalTemperatureAssessment, pressureIsHigh: Bool) -> String {
        guard isFresh else { return "Scan now to identify current activity. Older readings are not used to blame an app." }
        let needsReview = temperature.band.rawValue >= ThermalTemperatureBand.warm.rawValue || pressureIsHigh
        let isCooling = needsReview && temperature.trajectory.direction == .falling
        if isSubstantial, let leader {
            let subject = leader.isSystemProcess ? "service" : "app"
            let action = leader.isSystemProcess
                ? "Review related apps and optional work rather than stopping a system service."
                : "Inspect it, pause an optional task inside the app, then compare temperatures over the next minute."
            let cooling = isCooling ? " Temperature is falling; keep watching the next minute." : ""
            return "\(leader.displayName) is the busiest observed \(subject). Its activity is a plausible contributor, not proof of a fault. \(action)\(cooling)"
        }
        if needsReview, let recentLeader, let recentSecondsAgo {
            let cooling = isCooling ? " Temperature is falling." : ""
            return "\(recentLeader.displayName) showed substantial work \(recentSecondsAgo)s ago. Current readings do not confirm it continues.\(cooling) Check whether that work was expected and compare fresh activity and temperature readings as the Mac cools."
        }
        if isCooling {
            return "The measured temperature is falling. Keep optional heavy work paused and watch the next minute; the current reading still deserves attention."
        }
        if needsReview {
            let coverage = hasPartialCoverage ? "Readings are incomplete, so a workload may be missing." : "Recent work or unreported GPU activity may still matter."
            let observation = leader == nil
                ? "No strongly active app appears in this sample. This alone does not explain the temperature; recent work or activity outside readable processes may matter."
                : "Current activity does not explain this temperature with confidence."
            return "\(observation) \(coverage) Check ventilation, refresh the readings, and see whether the temperature settles."
        }
        if let leader {
            return "\(leader.displayName) leads this activity sample, but its measured load is modest. Being first in the list is not evidence of a problem."
        }
        if hasPartialCoverage {
            return "Activity coverage is incomplete. Scan again before deciding which app is responsible."
        }
        return "No strongly active app appears in this sample. This alone does not explain the temperature; recent work or activity outside readable processes may matter."
    }
}
