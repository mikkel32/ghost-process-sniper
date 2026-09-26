import Foundation

/// Incident rows: one open row per signature while it runs hot, resolved when
/// the family calms down or leaves the scan.
final class IncidentLedger {
    private static let chunkSize = 400

    private let db: SQLiteDatabase
    private let codec: StoreCodec

    init(db: SQLiteDatabase, codec: StoreCodec) {
        self.db = db
        self.codec = codec
    }

    func recent(limit: Int) throws -> [RadarIncident] {
        var incidents: [RadarIncident] = []
        try db.query(RadarStoreQueries.recentIncidents, [.int64(Int64(limit))]) { row in
            incidents.append(RadarStoreRows.incident(from: row, codec: codec))
        }
        return incidents
    }

    func recentCounts(for signatureIDs: [String], since: Date) throws -> [String: Int] {
        guard !signatureIDs.isEmpty else {
            return [:]
        }

        let uniqueIDs = Array(Set(signatureIDs))
        var counts: [String: Int] = [:]
        var start = 0
        while start < uniqueIDs.count {
            let end = min(start + Self.chunkSize, uniqueIDs.count)
            let chunk = Array(uniqueIDs[start..<end])
            let slots = SQLiteDatabase.placeholderCount(for: chunk.count)
            var values = chunk.map { SQLiteValue.text($0) }
            values += Array(repeating: .null, count: slots - chunk.count)
            values.append(.double(since.timeIntervalSince1970))
            try db.query(
                """
                SELECT signature_id, COUNT(*)
                FROM incidents
                WHERE signature_id IN (\(SQLiteDatabase.placeholders(count: slots))) AND started_at >= ?
                GROUP BY signature_id
                """,
                values
            ) { row in
                if let signatureID = row.string(0) {
                    counts[signatureID] = row.int(1)
                }
            }
            start = end
        }
        return counts
    }

    func record(_ families: [ProcessFamily], at date: Date) throws {
        let activeFamilies = families.filter {
            $0.score.heat.shouldRecordIncident &&
                $0.alertState.kind != .ignored &&
                $0.alertState.kind != .snoozed
        }
        let activeIDs = Set(activeFamilies.map(\.signature.id))

        for family in activeFamilies {
            if let existingID = try activeIncidentID(for: family.signature.id) {
                try db.execute(
                    """
                    UPDATE incidents
                    SET level = ?, max_score = MAX(max_score, ?), memory_bytes = ?, cpu_percent = ?,
                        leak_velocity = ?, reasons_json = ?, last_seen_at = ?
                    WHERE id = ?
                    """,
                    .text(family.score.level.label),
                    .double(family.score.value),
                    .int64(Int64(clamping: family.totalPhysicalFootprintBytes)),
                    .double(family.totalCPUPercent),
                    .double(family.trend.memoryVelocityMegabytesPerMinute),
                    .text(try codec.encode(family.score.reasons)),
                    .double(date.timeIntervalSince1970),
                    .text(existingID.uuidString)
                )
            } else {
                try db.execute(
                    """
                    INSERT INTO incidents(id, signature_id, display_name, canonical_path, command_fingerprint, family_name,
                                          level, max_score, memory_bytes, cpu_percent, leak_velocity, reasons_json,
                                          started_at, last_seen_at, resolved_at, occurrence_count)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 1)
                    """,
                    .text(UUID().uuidString),
                    .text(family.signature.id),
                    .text(family.signature.displayName),
                    .text(family.signature.canonicalPath),
                    .text(family.signature.commandFingerprint),
                    .text(family.displayName),
                    .text(family.score.level.label),
                    .double(family.score.value),
                    .int64(Int64(clamping: family.totalPhysicalFootprintBytes)),
                    .double(family.totalCPUPercent),
                    .double(family.trend.memoryVelocityMegabytesPerMinute),
                    .text(try codec.encode(family.score.reasons)),
                    .double(date.timeIntervalSince1970),
                    .double(date.timeIntervalSince1970)
                )
            }
        }

        var calmedIDs: [String] = []
        try db.query("SELECT signature_id FROM incidents WHERE resolved_at IS NULL") { row in
            if let signatureID = row.string(0), !activeIDs.contains(signatureID) {
                calmedIDs.append(signatureID)
            }
        }
        for signatureID in calmedIDs {
            try db.execute(
                "UPDATE incidents SET resolved_at = ?, last_seen_at = ? WHERE signature_id = ? AND resolved_at IS NULL",
                .double(date.timeIntervalSince1970),
                .double(date.timeIntervalSince1970),
                .text(signatureID)
            )
        }
    }

    private func activeIncidentID(for signatureID: String) throws -> UUID? {
        let text = try db.string(
            "SELECT id FROM incidents WHERE signature_id = ? AND resolved_at IS NULL LIMIT 1",
            [.text(signatureID)]
        )
        return text.flatMap(UUID.init(uuidString:))
    }
}
