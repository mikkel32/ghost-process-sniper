import Foundation

/// Latest forecast per signature, plus coalesced recommendation history and
/// predictive alerts.
final class ForecastLedger {
    private static let recommendationCooldown: TimeInterval = 30 * 60

    private let db: SQLiteDatabase
    private var lastRecommendationFingerprints: [String: RecommendationFingerprint] = [:]
    private(set) var lastStats: StoreCoalescingStats = .empty

    init(db: SQLiteDatabase) {
        self.db = db
    }

    func recentForecasts(limit: Int) throws -> [ForecastStoreSnapshot] {
        var forecasts: [ForecastStoreSnapshot] = []
        try db.query(RadarStoreQueries.recentForecasts, [.int64(Int64(limit))]) { row in
            forecasts.append(RadarStoreRows.forecastSnapshot(from: row))
        }
        return forecasts
    }

    func recentPredictiveAlerts(limit: Int) throws -> [PredictiveAlert] {
        var alerts: [PredictiveAlert] = []
        try db.query(RadarStoreQueries.recentPredictiveAlerts, [.int64(Int64(limit))]) { row in
            alerts.append(RadarStoreRows.predictiveAlert(from: row))
        }
        return alerts
    }

    func persist(_ families: [ProcessFamily], at date: Date, forecastCandidates: Int) throws {
        var recommendationWrites = 0
        var recommendationSkips = 0
        for family in families.prefix(64) {
            let forecast = family.forecast
            let generatedAt = forecast.generatedAt.timeIntervalSince1970 > 0 ? forecast.generatedAt : date
            try db.execute(
                """
                INSERT INTO forecasts(signature_id, state, confidence, eta_seconds, why_now,
                                      projected_memory_bytes, projected_cpu_percent, recurrence_risk,
                                      stale_likelihood, generated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(signature_id) DO UPDATE SET
                    state = excluded.state,
                    confidence = excluded.confidence,
                    eta_seconds = excluded.eta_seconds,
                    why_now = excluded.why_now,
                    projected_memory_bytes = excluded.projected_memory_bytes,
                    projected_cpu_percent = excluded.projected_cpu_percent,
                    recurrence_risk = excluded.recurrence_risk,
                    stale_likelihood = excluded.stale_likelihood,
                    generated_at = excluded.generated_at
                """,
                .text(family.signature.id),
                .text(forecast.state.rawValue),
                .double(forecast.confidence),
                forecast.etaSeconds.map { .double($0) } ?? .null,
                .text(forecast.whyNow),
                .int64(Int64(clamping: forecast.projectedMemoryBytes)),
                .double(forecast.projectedCPUPercent),
                .double(forecast.recurrenceRisk),
                .double(forecast.staleLikelihood),
                .double(generatedAt.timeIntervalSince1970)
            )

            guard forecast.state >= .warming, forecast.confidence >= 0.42 else {
                continue
            }
            guard shouldWriteRecommendation(for: family, at: generatedAt) else {
                recommendationSkips += 1
                continue
            }
            try db.execute(
                """
                INSERT INTO recommendation_history(id, signature_id, title, detail, action, confidence, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """,
                .text(UUID().uuidString),
                .text(family.signature.id),
                .text(forecast.recommendedAction.title),
                .text(forecast.recommendedAction.detail),
                .text(forecast.recommendedAction.action.rawValue),
                .double(forecast.recommendedAction.confidence),
                .double(generatedAt.timeIntervalSince1970)
            )
            recommendationWrites += 1

            guard forecast.state >= .leaking else {
                continue
            }
            try db.execute(
                """
                INSERT INTO predictive_alerts(id, signature_id, state, message, created_at)
                VALUES(?, ?, ?, ?, ?)
                """,
                .text(UUID().uuidString),
                .text(family.signature.id),
                .text(forecast.state.rawValue),
                .text(forecast.whyNow),
                .double(generatedAt.timeIntervalSince1970)
            )
        }
        lastStats = StoreCoalescingStats(
            forecastCandidates: forecastCandidates,
            forecastWrites: min(families.count, 64),
            recommendationWrites: recommendationWrites,
            recommendationSkippedCount: recommendationSkips
        )
    }

    private func shouldWriteRecommendation(for family: ProcessFamily, at date: Date) -> Bool {
        let fingerprint = RecommendationFingerprint(family: family, date: date)
        defer {
            lastRecommendationFingerprints[family.signature.id] = fingerprint
        }
        guard let previous = lastRecommendationFingerprints[family.signature.id] else {
            return true
        }
        if previous.state != fingerprint.state ||
            previous.title != fingerprint.title ||
            previous.detail != fingerprint.detail ||
            previous.action != fingerprint.action {
            return true
        }
        return date.timeIntervalSince(previous.createdAt) >= Self.recommendationCooldown
    }
}

private struct RecommendationFingerprint {
    var state: ForecastState
    var title: String
    var detail: String
    var action: RadarActionType
    var createdAt: Date

    init(family: ProcessFamily, date: Date) {
        state = family.forecast.state
        title = family.forecast.recommendedAction.title
        detail = family.forecast.recommendedAction.detail
        action = family.forecast.recommendedAction.action
        createdAt = date
    }
}
