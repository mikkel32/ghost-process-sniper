import Foundation

public struct MenuBarStatusPresentation: Equatable, Sendable {
    public let title: String
    public let compactStateText: String
    public let accessibilityLabel: String
    public let tooltip: String
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
        tooltip = Self.tooltip(
            summary: summary,
            normalizedStatus: status,
            engineStatus: engineStatus,
            metrics: metrics,
            storeError: storeError
        )
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

    private static func accessibilityLabel(summary: RadarSummary, normalizedStatus: String) -> String {
        let state: String
        if summary.level >= .critical {
            state = "Critical"
        } else if summary.hotCount > 0 {
            state = "\(summary.hotCount) hot famil\(summary.hotCount == 1 ? "y" : "ies")"
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
        if summary.hotCount > 0 {
            return "\(summary.hotCount) hot"
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

        var parts = [
            "Ghost Process Sniper: \(normalizedStatus)",
            "\(summary.familyCount) families",
            "\(summary.hotCount) hot",
            "\(summary.leakingCount) leaks"
        ]
        if metrics.duplicateClusterCount > 0 {
            parts.append("\(metrics.duplicateClusterCount) duplicate clusters")
        }
        return capped(parts.joined(separator: " - "), limit: 180)
    }

    private static func capped(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        let end = text.index(text.startIndex, offsetBy: max(1, limit - 1))
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
