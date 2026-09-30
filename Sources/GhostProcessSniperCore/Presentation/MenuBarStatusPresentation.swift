import Foundation

public struct MenuBarStatusPresentation: Equatable, Sendable {
    public let title: String
    public let compactStateText: String
    public let accessibilityLabel: String
    public let tooltip: String
    /// The right-click menu's first line: short, so it does not set the menu's width.
    public let menuTitle: String
    /// "4 to review", the console's own wording; nil when nothing needs review.
    public let reviewText: String?
    public let level: GhostLevel
    public let renderKey: String

    public init(state: ProcessMonitorPublishedState) {
        self.init(
            summary: state.summary,
            engineStatus: state.engineStatus,
            metrics: state.performanceMetrics,
            storeError: state.storeError
        )
    }

    public init(
        summary: RadarSummary,
        engineStatus: EngineStatusSnapshot,
        metrics: RadarPerformanceMetrics,
        storeError: String? = nil
    ) {
        let status = Self.normalizedStatus(summary.statusText)
        title = ""
        level = summary.level
        compactStateText = Self.compactStateText(summary: summary, normalizedStatus: status)
        accessibilityLabel = Self.accessibilityLabel(summary: summary, normalizedStatus: status)
        reviewText = Self.reviewText(summary: summary)
        tooltip = Self.tooltip(
            summary: summary,
            normalizedStatus: status,
            engineStatus: engineStatus,
            metrics: metrics,
            storeError: storeError
        )
        menuTitle = Self.menuTitle(summary: summary, normalizedStatus: status, storeError: storeError)
        renderKey = [
            title,
            compactStateText,
            accessibilityLabel,
            tooltip,
            level.label
        ].joined(separator: "|")
    }

    public static func normalizedStatus(_ status: String) -> String {
        var normalized = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "No threshold ETA", with: "no ETA", options: [.caseInsensitive])
            .replacingOccurrences(of: "no threshold ETA", with: "no ETA", options: [.caseInsensitive])

        if normalized.lowercased() == "warming no eta" {
            normalized = "Warming, no ETA"
        } else if normalized.lowercased().hasPrefix("warming no eta") {
            normalized = normalized.replacingOccurrences(of: "Warming no ETA", with: "Warming, no ETA", options: [.caseInsensitive])
        }

        return capped(normalized.isEmpty ? "Quiet" : normalized, limit: 44)
    }

    /// The popover's state text without building the tooltip and render key.
    public static func compactStateText(summary: RadarSummary) -> String {
        compactStateText(summary: summary, normalizedStatus: normalizedStatus(summary.statusText))
    }

    private static func accessibilityLabel(summary: RadarSummary, normalizedStatus: String) -> String {
        let state: String
        if summary.level >= .critical {
            state = "Critical"
        } else if summary.hotCount > 0 {
            state = summary.hotCount == 1 ? "1 needs review" : "\(summary.hotCount) need review"
        } else if summary.leakingCount > 0 || normalizedStatus.lowercased().contains("leak") {
            state = "Leak detected"
        } else if normalizedStatus.lowercased().contains("warming") {
            state = "Warming"
        } else {
            state = normalizedStatus
        }
        return capped("Ghost Process Sniper, \(state)", limit: 72)
    }

    private static func compactStateText(summary: RadarSummary, normalizedStatus: String) -> String {
        if summary.level >= .critical {
            return "Critical"
        }
        if let review = reviewText(summary: summary) {
            return review
        }
        if summary.leakingCount > 0 || normalizedStatus.lowercased().contains("leak") {
            return "Leak"
        }
        if normalizedStatus.lowercased().contains("warming") {
            return "Warm"
        }
        if normalizedStatus.lowercased() == "watching" {
            return "Watch"
        }
        return capped(normalizedStatus, limit: 8)
    }

    private static func reviewText(summary: RadarSummary) -> String? {
        summary.hotCount > 0 ? "\(summary.hotCount) to review" : nil
    }

    /// What the tooltip and the menu title open with, each fact once: what
    /// needs review, the status only when it says more than that count (the
    /// summary's own status is often that count), and the leaks.
    private static func headlineFacts(summary: RadarSummary, normalizedStatus: String) -> [String] {
        let review = reviewText(summary: summary)
        var facts = [review].compactMap { $0 }
        if normalizedStatus.lowercased() != review?.lowercased() {
            facts.append(normalizedStatus)
        }
        if summary.leakingCount > 0 {
            facts.append(counted(summary.leakingCount, "leak", "leaks"))
        }
        return facts
    }

    private static func tooltip(
        summary: RadarSummary,
        normalizedStatus: String,
        engineStatus: EngineStatusSnapshot,
        metrics: RadarPerformanceMetrics,
        storeError: String?
    ) -> String {
        if let storeError, !storeError.isEmpty {
            return capped("Ghost Process Sniper: \(storeError)", limit: 160)
        }

        var parts = headlineFacts(summary: summary, normalizedStatus: normalizedStatus)
        parts.append(counted(summary.familyCount, "family", "families"))
        if metrics.duplicateClusterCount > 0 {
            parts.append(counted(metrics.duplicateClusterCount, "duplicate cluster", "duplicate clusters"))
        }
        return capped("Ghost Process Sniper: " + parts.joined(separator: " - "), limit: 180)
    }

    // A long store error stays in the hover text; the menu says only that
    // history is not being saved, as the popover's warning does.
    private static func menuTitle(summary: RadarSummary, normalizedStatus: String, storeError: String?) -> String {
        if let storeError, !storeError.isEmpty {
            return "Ghost Process Sniper: History not saved"
        }
        let facts = headlineFacts(summary: summary, normalizedStatus: normalizedStatus)
        return capped("Ghost Process Sniper: " + facts.joined(separator: " - "), limit: 60)
    }

    private static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// At most `limit` characters, the ellipsis included.
    private static func capped(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        let end = text.index(text.startIndex, offsetBy: max(1, limit - 3))
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
