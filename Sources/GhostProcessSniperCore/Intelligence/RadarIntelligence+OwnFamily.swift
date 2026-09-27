import Foundation

extension RadarIntelligence {
    func isOwnFamily(_ family: ProcessFamily) -> Bool {
        family.root.pid == ownPID || family.members.contains { $0.pid == ownPID }
    }

    /// Ghost is measured like any other app but never flagged, queued or
    /// notified about: it cannot stop itself, and Settings › Diagnostics
    /// already reports what it costs.
    func ownFamily(_ family: ProcessFamily, now: Date) -> ProcessFamily {
        let score = GhostScore(value: 0, level: .quiet, reasons: ["Ghost Process Sniper itself; see Settings › Diagnostics"],
                               heat: .quiet)
        return family.enriched(score: score, suggestions: [], alertState: .normal, forecast: .quiet, lastScoredAt: now)
    }
}
