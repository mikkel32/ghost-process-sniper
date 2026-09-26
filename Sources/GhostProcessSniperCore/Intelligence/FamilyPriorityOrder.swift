import Foundation

/// The one ranking the scoring pipeline presents families in:
/// most urgent first, then by name so equal families never reshuffle.
enum FamilyPriorityOrder {
    static func areInIncreasingOrder(_ lhs: ProcessFamily, _ rhs: ProcessFamily) -> Bool {
        let left = RankKey(lhs)
        let right = RankKey(rhs)
        if left != right {
            return left.ranksBefore(right)
        }
        return namesInIncreasingOrder(lhs, rhs)
    }

    /// Sorts through small numeric keys and indices: moving whole families
    /// around inside the sort cost more than scoring them.
    static func sorted(_ families: [ProcessFamily]) -> [ProcessFamily] {
        let keys = families.map(RankKey.init)
        let order = families.indices.sorted { lhs, rhs in
            if keys[lhs] != keys[rhs] {
                return keys[lhs].ranksBefore(keys[rhs])
            }
            return namesInIncreasingOrder(families[lhs], families[rhs])
        }
        return order.map { families[$0] }
    }

    private struct RankKey: Equatable {
        let forecast: Int
        let level: Int
        let alert: Int
        let heat: Double
        let score: Double
        let footprint: UInt64
        let cpu: Double

        init(_ family: ProcessFamily) {
            forecast = family.forecast.state.severityRank
            level = family.score.level.rawValue
            alert = FamilyPriorityOrder.alertPriority(family.alertState.kind)
            heat = family.score.heat.value
            score = family.score.value
            footprint = family.totalPhysicalFootprintBytes
            cpu = family.totalCPUPercent
        }

        func ranksBefore(_ other: RankKey) -> Bool {
            if forecast != other.forecast { return forecast > other.forecast }
            if level != other.level { return level > other.level }
            if alert != other.alert { return alert > other.alert }
            if heat != other.heat { return heat > other.heat }
            if score != other.score { return score > other.score }
            if footprint != other.footprint { return footprint > other.footprint }
            return cpu > other.cpu
        }
    }

    private static func namesInIncreasingOrder(_ lhs: ProcessFamily, _ rhs: ProcessFamily) -> Bool {
        // Equal names are common (every "node"); skip the costly compare.
        if lhs.displayName == rhs.displayName {
            return lhs.familyKey < rhs.familyKey
        }
        switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        // The builder emits families in no particular order.
        case .orderedSame: return lhs.familyKey < rhs.familyKey
        }
    }

    private static func alertPriority(_ kind: AlertStateKind) -> Int {
        switch kind {
        case .new: 4
        case .recurring: 3
        case .normal: 2
        case .snoozed: 1
        case .ignored: 0
        }
    }
}
