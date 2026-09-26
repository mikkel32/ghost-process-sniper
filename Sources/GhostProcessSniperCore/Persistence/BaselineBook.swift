import Foundation

/// Learned per-signature baselines. Rows are cached after the first read, and
/// signatures known to have no row are remembered, so a refresh never re-reads
/// what it already knows.
///
/// Writes are staged until the caller's transaction commits: a rolled-back
/// flush that is retried must not learn the same samples twice.
final class BaselineBook {
    private static let maximumUpdates = 512
    // Keeps the cold-load query comfortably below SQLite variable limits.
    private static let chunkSize = 400

    private let db: SQLiteDatabase
    private var cache: [String: FamilyBaseline] = [:]
    private var staged: [String: FamilyBaseline] = [:]
    private var knownMissing: Set<String> = []
    private var roundRobinOffset = 0

    init(db: SQLiteDatabase) {
        self.db = db
    }

    func baselines(for signatureIDs: [String]) throws -> [String: FamilyBaseline] {
        guard !signatureIDs.isEmpty else {
            return [:]
        }

        let uniqueIDs = Array(Set(signatureIDs))
        var result: [String: FamilyBaseline] = [:]
        result.reserveCapacity(uniqueIDs.count)
        var missing: [String] = []
        missing.reserveCapacity(uniqueIDs.count)

        for signatureID in uniqueIDs {
            if let pending = staged[signatureID] {
                result[signatureID] = pending
            } else if let cached = cache[signatureID] {
                result[signatureID] = cached
            } else if !knownMissing.contains(signatureID) {
                missing.append(signatureID)
            }
        }

        var start = 0
        while start < missing.count {
            let end = min(start + Self.chunkSize, missing.count)
            let chunk = Array(missing[start..<end])
            let slots = SQLiteDatabase.placeholderCount(for: chunk.count)
            var values = chunk.map { SQLiteValue.text($0) }
            values += Array(repeating: .null, count: slots - chunk.count)

            var found = Set<String>()
            try db.query(
                """
                SELECT \(RadarStoreRows.baselineColumns)
                FROM baselines
                WHERE signature_id IN (\(SQLiteDatabase.placeholders(count: slots)))
                """,
                values
            ) { row in
                let baseline = RadarStoreRows.baseline(from: row)
                let signatureID = baseline.signature.id
                cache[signatureID] = baseline
                knownMissing.remove(signatureID)
                result[signatureID] = baseline
                found.insert(signatureID)
            }

            for signatureID in chunk where !found.contains(signatureID) {
                knownMissing.insert(signatureID)
            }
            start = end
        }
        return result
    }

    func learn(from families: [ProcessFamily], at date: Date) throws {
        let candidates = updateCandidates(from: families)
        let existing = try baselines(for: candidates.map(\.signature.id))
        let learner = FamilyBaselineLearner()
        for family in candidates {
            let baseline = learner.updated(
                existing: existing[family.signature.id],
                family: family,
                now: date
            )
            try upsert(baseline)
        }
    }

    func commitStaged() {
        for (signatureID, baseline) in staged {
            cache[signatureID] = baseline
            knownMissing.remove(signatureID)
        }
        staged.removeAll(keepingCapacity: true)
    }

    func discardStaged() {
        staged.removeAll(keepingCapacity: true)
    }

    private func updateCandidates(from families: [ProcessFamily]) -> [ProcessFamily] {
        let maximumUpdates = Self.maximumUpdates
        var seenSignatures = Set<String>()
        let uniqueFamilies = families.filter { family in
            seenSignatures.insert(family.signature.id).inserted
        }
        guard uniqueFamilies.count > maximumUpdates else {
            return uniqueFamilies
        }

        // Always spend part of the budget on families that can affect the
        // current diagnosis. Quiet families still learn through a rotating
        // slice, so a huge process table cannot turn into thousands of SQLite
        // upserts every flush.
        let priorityLimit = maximumUpdates / 2
        var selected: [ProcessFamily] = []
        selected.reserveCapacity(maximumUpdates)
        var selectedIDs = Set<String>()

        for family in uniqueFamilies where
            family.score.level >= .watch ||
            family.forecastIsCredibleEarlyWarning ||
            family.recentIncidentCount > 0 {
            guard selected.count < priorityLimit else { break }
            selected.append(family)
            selectedIDs.insert(family.signature.id)
        }

        let quiet = uniqueFamilies.filter { !selectedIDs.contains($0.signature.id) }
        guard !quiet.isEmpty, selected.count < maximumUpdates else {
            return selected
        }

        let start = roundRobinOffset % quiet.count
        let remaining = maximumUpdates - selected.count
        for offset in 0..<min(remaining, quiet.count) {
            selected.append(quiet[(start + offset) % quiet.count])
        }
        roundRobinOffset = (start + remaining) % quiet.count
        return selected
    }

    private func upsert(_ baseline: FamilyBaseline) throws {
        try db.execute(
            """
            INSERT INTO baselines(\(RadarStoreRows.baselineColumns))
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(signature_id) DO UPDATE SET
                display_name = excluded.display_name,
                canonical_path = excluded.canonical_path,
                command_fingerprint = excluded.command_fingerprint,
                sample_count = excluded.sample_count,
                mean_memory_bytes = excluded.mean_memory_bytes,
                peak_memory_bytes = excluded.peak_memory_bytes,
                mean_cpu_percent = excluded.mean_cpu_percent,
                peak_cpu_percent = excluded.peak_cpu_percent,
                mean_leak_velocity = excluded.mean_leak_velocity,
                incident_count = excluded.incident_count,
                last_seen_at = excluded.last_seen_at,
                first_seen_at = excluded.first_seen_at,
                measurement_version = excluded.measurement_version
            """,
            .text(baseline.signature.id),
            .text(baseline.signature.displayName),
            .text(baseline.signature.canonicalPath),
            .text(baseline.signature.commandFingerprint),
            .int64(Int64(baseline.sampleCount)),
            .double(baseline.meanMemoryBytes),
            .int64(Int64(clamping: baseline.peakMemoryBytes)),
            .double(baseline.meanCPUPercent),
            .double(baseline.peakCPUPercent),
            .double(baseline.meanLeakVelocityMegabytesPerMinute),
            .int64(Int64(baseline.incidentCount)),
            .double(baseline.firstSeenAt.timeIntervalSince1970),
            .double(baseline.lastSeenAt.timeIntervalSince1970),
            .int64(Int64(baseline.measurementVersion ?? 0))
        )
        staged[baseline.signature.id] = baseline
    }
}
