import Foundation

/// Decides which families earn a notification, like the Sentinel and Energy
/// gates do for their findings: a family that stays Hot alerts once however
/// long it lasts, again when it gets worse, and as a slow reminder after half
/// a day. Alerts also share a rolling budget, most urgent first, so a launch
/// with many hot families does not post a banner each, and families that
/// already alerted never use up the slots a new one needs.
///
/// The gate only plans. The notifier reports `delivered` after macOS accepts
/// the request, so a family it could not deliver (permission not granted yet)
/// is offered again on the next pass.
public struct FamilyAlertGate: Sendable {
    public struct Candidate: Equatable, Sendable {
        /// The family's signature id, which is also its notification identifier.
        public var id: String
        public var level: GhostLevel

        public init(id: String, level: GhostLevel) {
            self.id = id
            self.level = level
        }
    }

    public static let reminderInterval: TimeInterval = 12 * 60 * 60
    /// The soonest a family that got worse alerts again.
    public static let escalationSpacing: TimeInterval = 5 * 60
    /// A family that left and came back waits this long after its last alert.
    public static let reentryCooldown: TimeInterval = 30 * 60
    /// Absent this long, a family's episode is over: a dip in heat, a snooze or
    /// an ignore is not, so a flicker is never a new episode.
    public static let absenceGrace: TimeInterval = 2 * 60
    /// At most this many alerts in any `budgetWindow`.
    public static let budget = 3
    public static let budgetWindow: TimeInterval = 10 * 60

    private struct Episode {
        var lastSeen: Date
        /// The worst level announced in this episode and when it last alerted.
        var alerted: (level: GhostLevel, at: Date)?
    }

    private var episodes: [String: Episode] = [:]
    /// Survives the episode, so a family that flaps cannot alert each time it returns.
    private var lastDelivered: [String: Date] = [:]
    private var recent: [Date] = []

    public init() {}

    /// Episodes and cooldown entries held; for tests.
    var trackedCount: Int { episodes.count + lastDelivered.count }

    /// The ids to alert now, from `candidates` in priority order. Memory stays
    /// bounded: episodes end after the grace period, entries after the cooldown.
    public mutating func plan(_ candidates: [Candidate], now: Date) -> [String] {
        for candidate in candidates {
            episodes[candidate.id, default: Episode(lastSeen: now)].lastSeen = now
        }
        let present = Set(candidates.map(\.id))
        episodes = episodes.filter { present.contains($0.key) || now.timeIntervalSince($0.value.lastSeen) < Self.absenceGrace }
        lastDelivered = lastDelivered.filter { now.timeIntervalSince($0.value) < Self.reentryCooldown }
        recent.removeAll { now.timeIntervalSince($0) >= Self.budgetWindow }

        var room = Self.budget - recent.count
        var planned: [String] = []
        for candidate in candidates {
            guard room > 0 else { break }
            guard !planned.contains(candidate.id), shouldAlert(candidate, now: now) else { continue }
            planned.append(candidate.id)
            room -= 1
        }
        return planned
    }

    /// The notifier posted the alert.
    public mutating func delivered(_ id: String, level: GhostLevel, at now: Date) {
        let worst = max(level, episodes[id]?.alerted?.level ?? .quiet)
        episodes[id, default: Episode(lastSeen: now)].alerted = (worst, now)
        lastDelivered[id] = now
        recent.append(now)
    }

    private func shouldAlert(_ candidate: Candidate, now: Date) -> Bool {
        if let alerted = episodes[candidate.id]?.alerted {
            let since = now.timeIntervalSince(alerted.at)
            return since >= Self.reminderInterval
                || (candidate.level > alerted.level && since >= Self.escalationSpacing)
        }
        // Nothing announced in this episode: only a family that alerted just
        // before it ended is held back (the cooldown table holds those alone).
        return lastDelivered[candidate.id] == nil
    }
}
