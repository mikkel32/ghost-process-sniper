/// Selects bounded rotating cohorts. A stable PID list must not permanently hide a process.
enum RichProbeSelector {
    /// Priority 2 is explicit focus/alert demand, 1 is a developer-name hint, 0 is discovery.
    static func indices(priorities: [Int], budget: Int, pass: UInt64) -> [Int] {
        let limit = min(priorities.count, max(0, budget))
        guard limit > 0 else { return [] }
        var focused: [Int] = []
        var hinted: [Int] = []
        var discovery: [Int] = []
        for index in priorities.indices {
            switch priorities[index] {
            case 2...: focused.append(index)
            case 1: hinted.append(index)
            default: discovery.append(index)
            }
        }
        // One quarter remains available for discovering non-developer apps.
        // With a single slot, alternate discovery and priority work.
        let reserve = discovery.isEmpty ? 0 : limit == 1
            ? (pass % 2 == 0 || focused.isEmpty && hinted.isEmpty ? 1 : 0)
            : min(discovery.count, max(1, limit / 4))
        let focusCount = min(focused.count, limit - reserve)
        let hintedCount = min(hinted.count, limit - reserve - focusCount)
        let discoveryCount = min(discovery.count, limit - focusCount - hintedCount)
        let cohortPass = limit == 1 && !discovery.isEmpty && (!focused.isEmpty || !hinted.isEmpty) ? pass / 2 : pass
        return rotated(focused, count: focusCount, pass: cohortPass) +
            rotated(discovery, count: discoveryCount, pass: cohortPass) +
            rotated(hinted, count: hintedCount, pass: cohortPass)
    }

    private static func rotated(_ values: [Int], count: Int, pass: UInt64) -> [Int] {
        guard count > 0, !values.isEmpty else { return [] }
        // Single-slot alternation advances each cohort only when it is sampled.
        let offset = Int((pass &* UInt64(count)) % UInt64(values.count))
        return (0..<count).map { values[(offset + $0) % values.count] }
    }
}
