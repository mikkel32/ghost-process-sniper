import Foundation

/// Rolls scored families up into the menu-bar level and status line.
enum RadarSummaryBuilder {
    static func summary(for families: [ProcessFamily]) -> RadarSummary {
        let level = families.map { family in
            family.forecastIsCredibleEscalation
                ? max(family.score.level, family.forecast.state.level)
                : family.score.level
        }.max() ?? .quiet
        let hotCount = families.filter { $0.score.level >= .hot || $0.forecastIsCredibleEscalation }.count
        let leakingCount = families.filter {
            $0.forecastIsCredibleEscalation && $0.forecast.state >= .leaking
        }.count
        let suggestionCount = families.reduce(0) { $0 + $1.suggestions.count }
        let totalMemory = families.reduce(UInt64(0)) { $0 + $1.totalPhysicalFootprintBytes }
        let top = families.first

        let statusText: String
        if let topForecast = families.first(where: { $0.forecastIsCredibleEscalation }) {
            statusText = escalationText(topForecast.forecast)
        } else if let topWarming = families.first(where: { $0.forecastIsCredibleEarlyWarning }) {
            statusText = earlyWarningText(topWarming.forecast)
        } else if let topGPU = families.first(where: { $0.totalGPUPercent >= 25 }) {
            statusText = "GPU \(Int(topGPU.totalGPUPercent.rounded()))%"
        } else if hotCount > 0 {
            statusText = "\(hotCount) hot"
        } else if let top, top.score.level == .watch {
            statusText = "Watching"
        } else if let top, top.totalPhysicalFootprintBytes > 0 {
            statusText = RadarFormat.bytes(top.totalPhysicalFootprintBytes)
        } else {
            statusText = "Quiet"
        }

        return RadarSummary(
            statusText: statusText,
            level: level,
            familyCount: families.count,
            hotCount: hotCount,
            totalMemoryBytes: totalMemory,
            topFamilyName: top?.displayName,
            leakingCount: leakingCount,
            suggestionCount: suggestionCount
        )
    }

    // Only a memory countdown earns an ETA suffix; a CPU breach or an
    // unbounded climb reads as the state alone.
    private static func escalationText(_ forecast: RiskForecast) -> String {
        guard forecast.state == .leaking else { return forecast.state.label }
        guard forecast.etaKind != .none, forecast.etaSeconds != nil else { return "Leak" }
        return "Leak \(forecast.etaText)"
    }

    private static func earlyWarningText(_ forecast: RiskForecast) -> String {
        if forecast.state == .stale { return "Forgotten?" }
        guard forecast.etaKind != .none, forecast.etaSeconds != nil else { return "Warming" }
        return "Warming \(forecast.etaText)"
    }
}
