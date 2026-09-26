import Foundation

/// Activity describes an observed workload; neither coverage nor a zero GPU
/// counter proves that every source of heat was measured.
struct ThermalWorkloadAssessment {
    let isFresh: Bool
    let isSubstantial: Bool
    let coverageText: String

    init(activity: ThermalActivitySummary, at now: Date) {
        isFresh = (0...ThermalActivitySummary.maximumAge).contains(now.timeIntervalSince(activity.sampledAt))
        isSubstantial = isFresh && activity.visibleContributors(at: now).contains { $0.isSubstantial(at: now) }
        coverageText = isFresh
            ? "Process sample: CPU measured for \(activity.cpuObservedProcessCount) of \(activity.observedProcessCount) processes; GPU activity reported for \(activity.gpuObservedProcessCount). \(activity.unavailableProcessCount) without either reading."
            : "Process activity needs a fresh scan"
    }
}
