import Foundation

extension RadarIntelligenceBrief {
    /// The verdict when nothing is worth naming: no Hot family and no early
    /// warning. Families watched for their size alone are counted here, not
    /// announced: the detail says what was checked for, so it stays true.
    static func calm(summary: RadarSummary, warmingRows: [CompactSidebarRowModel]) -> RadarIntelligenceBrief {
        let hasFamilies = summary.familyCount > 0
        let watchedForSize = hasFamilies && !warmingRows.isEmpty && warmingRows.allSatisfy(\.isWatchedForSizeOnly)
        let detail: String
        let evidence: [String]
        if watchedForSize {
            let count = warmingRows.count
            detail = "\(count) \(count == 1 ? "family is" : "families are") watched for size only, " +
                "with no growth, high CPU, duplicates or a forgotten process tree."
            let largest = warmingRows.sorted { lhs, rhs in
                lhs.memoryBytes != rhs.memoryBytes ? lhs.memoryBytes > rhs.memoryBytes : lhs.id < rhs.id
            }
            evidence = largest.prefix(3).map { "\($0.title) \(RadarFormat.bytes($0.memoryBytes))" }
        } else {
            detail = hasFamilies
                ? "Current readings and trends show no credible leak, runaway load, or forgotten process tree."
                : "The last scan found nothing in the radar's scope: no developer tools, and nothing heavy or duplicated."
            evidence = hasFamilies ? ["Current readings", "Trend shape", "Host pressure"] : []
        }
        return RadarIntelligenceBrief(
            eyebrow: "Live guidance",
            title: hasFamilies ? "No credible problems right now" : "Nothing to watch right now",
            detail: detail,
            recommendation: hasFamilies
                ? "Keep working normally. The radar will surface a clear next step if behavior changes."
                : "Nothing to do. To watch more of your Mac, widen the scope to Heavy or All in Settings.",
            confidenceText: "Continuous",
            evidence: evidence,
            familyKey: nil,
            familyName: nil,
            actionTitle: "Review",
            systemImage: "checkmark.seal",
            level: .quiet
        )
    }
}
