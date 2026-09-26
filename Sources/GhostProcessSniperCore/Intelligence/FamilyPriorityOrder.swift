import Foundation

/// The one ranking shared by the family builder and the scoring pipeline:
/// most urgent first, then by name so equal families never reshuffle.
enum FamilyPriorityOrder {
    static func areInIncreasingOrder(_ lhs: ProcessFamily, _ rhs: ProcessFamily) -> Bool {
        if lhs.forecast.state != rhs.forecast.state {
            return lhs.forecast.state > rhs.forecast.state
        }
        if lhs.score.level != rhs.score.level {
            return lhs.score.level > rhs.score.level
        }
        if lhs.alertState.kind != rhs.alertState.kind {
            return alertPriority(lhs.alertState.kind) > alertPriority(rhs.alertState.kind)
        }
        if lhs.score.heat.value != rhs.score.heat.value {
            return lhs.score.heat.value > rhs.score.heat.value
        }
        if lhs.score.value != rhs.score.value {
            return lhs.score.value > rhs.score.value
        }
        if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes {
            return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes
        }
        if lhs.totalCPUPercent != rhs.totalCPUPercent {
            return lhs.totalCPUPercent > rhs.totalCPUPercent
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
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
