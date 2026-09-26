import Foundation

/// Keeps the monitor's published sensor reading and its trend window in step.
enum ThermalSnapshotStore {
    /// Nil when the sampler handed back the cached reading already published: the
    /// monitor then skips the assignment, because an observable property notifies
    /// its readers on every set, equal or not.
    static func update(_ current: ThermalSnapshot, _ observations: ThermalObservationWindow,
                       with sampled: ThermalSnapshot, at now: Date) -> (ThermalSnapshot, ThermalObservationWindow)? {
        guard sampled != current else { return nil }
        var next = observations
        if sampled.sampledAt != current.sampledAt { next.record(sampled, at: now) }
        return (sampled, next)
    }
}
