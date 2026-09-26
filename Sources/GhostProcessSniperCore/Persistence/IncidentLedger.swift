import Foundation

/// Incident episodes. A family that runs hot opens one row that stays open
/// through dips, snoozes and skipped samples, and closes only after
/// `closeAfter` without activity. A return within `reopenWindow` reopens the
/// same row and counts a hit instead of inserting another.
///
/// Open episodes live in memory, so a tick costs a row write only when an
/// episode starts, peaks, closes or has not been written for
/// `refreshInterval`. Changes are staged until the caller's transaction
/// commits, like the baseline cache.
final class IncidentLedger {
    static let closeAfter: TimeInterval = 90
    static let reopenWindow: TimeInterval = 10 * 60
    static let refreshInterval: TimeInterval = 30
    private static let chunkSize = 400

    struct Peak: Equatable {
        var level: GhostLevel
        var score: Double
        var memoryBytes: UInt64

        mutating func absorb(_ family: ProcessFamily) {
            level = max(level, family.score.level)
            score = max(score, family.score.value)
            memoryBytes = max(memoryBytes, family.totalPhysicalFootprintBytes)
        }
    }

    struct OpenIncident: Equatable {
        let id: UUID
        var peak: Peak
        var lastActiveAt: Date
        var lastWrittenAt: Date
    }

    struct ClosedIncident: Equatable {
        let id: UUID
        let resolvedAt: Date
        let peak: Peak
    }

    struct Episodes: Equatable {
        var open: [String: OpenIncident] = [:]
        var recentlyClosed: [String: ClosedIncident] = [:]
    }

    private let db: SQLiteDatabase
    private let codec: StoreCodec
    private var committed: Episodes?
    private var staged: Episodes?
    private var pendingWrites: [(sql: String, values: [SQLiteValue])] = []

    init(db: SQLiteDatabase, codec: StoreCodec) {
        self.db = db
        self.codec = codec
    }

    var hasPendingWrites: Bool {
        !pendingWrites.isEmpty
    }

    func recent(limit: Int) throws -> [RadarIncident] {
        var incidents: [RadarIncident] = []
        try db.query(RadarStoreQueries.recentIncidents, [.int64(Int64(limit))]) { row in
            incidents.append(RadarStoreRows.incident(from: row, codec: codec))
        }
        return incidents
    }

    /// Past episodes per signature. The open incident is the episode in
    /// progress, so counting it would make every first incident recurring.
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
                WHERE signature_id IN (\(SQLiteDatabase.placeholders(count: slots))) AND started_at >= ? AND resolved_at IS NOT NULL
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

    /// Advances the staged episodes by one model and queues the row writes it
    /// implies. Nothing touches the database until `writeStaged`, apart from
    /// the one-time read of open episodes.
    func stage(_ families: [ProcessFamily], at date: Date) throws {
        var episodes = try staged ?? committed ?? load(now: date)

        // Identical instances share a signature, and so share one episode.
        var representatives: [String: ProcessFamily] = [:]
        var order: [String] = []
        for family in families where family.score.heat.shouldRecordIncident {
            let signatureID = family.signature.id
            if let current = representatives[signatureID] {
                if family.score.value > current.score.value {
                    representatives[signatureID] = family
                }
            } else {
                representatives[signatureID] = family
                order.append(signatureID)
            }
        }

        for signatureID in order {
            guard let family = representatives[signatureID] else { continue }
            if family.alertState.kind == .ignored || family.alertState.kind == .snoozed {
                // Still running hot: a muted family keeps its episode going but
                // neither writes to it nor starts a new one.
                episodes.open[signatureID]?.lastActiveAt = date
            } else if var open = episodes.open[signatureID] {
                update(&open, with: family, at: date)
                episodes.open[signatureID] = open
            } else if let closed = episodes.recentlyClosed[signatureID],
                      date.timeIntervalSince(closed.resolvedAt) < Self.reopenWindow {
                episodes.open[signatureID] = reopen(closed, with: family, at: date)
                episodes.recentlyClosed[signatureID] = nil
            } else {
                episodes.open[signatureID] = try insert(family, at: date)
            }
        }

        for (signatureID, open) in episodes.open where date.timeIntervalSince(open.lastActiveAt) >= Self.closeAfter {
            queueClose(open)
            episodes.open[signatureID] = nil
            episodes.recentlyClosed[signatureID] = ClosedIncident(id: open.id, resolvedAt: open.lastActiveAt, peak: open.peak)
        }
        episodes.recentlyClosed = episodes.recentlyClosed.filter {
            date.timeIntervalSince($0.value.resolvedAt) < Self.reopenWindow
        }
        staged = episodes
    }

    func writeStaged() throws {
        for write in pendingWrites {
            try db.execute(write.sql, values: write.values)
        }
    }

    func commitStaged() {
        if let staged {
            committed = staged
        }
        staged = nil
        pendingWrites.removeAll(keepingCapacity: true)
    }

    func discardStaged() {
        staged = nil
        pendingWrites.removeAll(keepingCapacity: true)
    }

    /// The file was replaced, so the tracked rows are gone; the next model
    /// reloads the episodes from the new file.
    func reset() {
        committed = nil
        discardStaged()
    }

    private func update(_ open: inout OpenIncident, with family: ProcessFamily, at date: Date) {
        let previous = open.peak
        open.peak.absorb(family)
        open.lastActiveAt = date
        let escalated = open.peak.level > previous.level
        // Small drifts wait for the periodic refresh; the tracked peak is exact
        // and is what gets written then.
        let peakRose = escalated ||
            open.peak.score >= previous.score + 1 ||
            Double(open.peak.memoryBytes) >= Double(previous.memoryBytes) * 1.05
        guard peakRose || date.timeIntervalSince(open.lastWrittenAt) >= Self.refreshInterval else {
            return
        }
        open.lastWrittenAt = date
        var values: [SQLiteValue] = [
            .text(open.peak.level.label),
            .double(open.peak.score),
            .int64(Int64(clamping: open.peak.memoryBytes)),
            .double(family.totalCPUPercent),
            .double(family.trend.memoryVelocityMegabytesPerMinute),
            .double(date.timeIntervalSince1970)
        ]
        // The reasons that explain the peak level, not the latest tick's.
        if escalated, let reasons = try? codec.encode(family.score.reasons) {
            values += [.text(reasons), .text(open.id.uuidString)]
            pendingWrites.append((RadarStoreQueries.escalateIncident, values))
        } else {
            values.append(.text(open.id.uuidString))
            pendingWrites.append((RadarStoreQueries.refreshIncident, values))
        }
    }

    private func reopen(_ closed: ClosedIncident, with family: ProcessFamily, at date: Date) -> OpenIncident {
        var peak = closed.peak
        peak.absorb(family)
        pendingWrites.append((
            RadarStoreQueries.reopenIncident,
            [
                .double(date.timeIntervalSince1970),
                .text(peak.level.label),
                .double(peak.score),
                .int64(Int64(clamping: peak.memoryBytes)),
                .double(family.totalCPUPercent),
                .double(family.trend.memoryVelocityMegabytesPerMinute),
                .text(closed.id.uuidString)
            ]
        ))
        return OpenIncident(id: closed.id, peak: peak, lastActiveAt: date, lastWrittenAt: date)
    }

    private func insert(_ family: ProcessFamily, at date: Date) throws -> OpenIncident {
        let id = UUID()
        pendingWrites.append((
            RadarStoreQueries.insertIncident,
            [
                .text(id.uuidString),
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
            ]
        ))
        let peak = Peak(level: family.score.level, score: family.score.value, memoryBytes: family.totalPhysicalFootprintBytes)
        return OpenIncident(id: id, peak: peak, lastActiveAt: date, lastWrittenAt: date)
    }

    /// Resolves at the last activity, never at the time the close is noticed,
    /// and carries any peak that was still waiting for a refresh.
    private func queueClose(_ open: OpenIncident) {
        let lastActive = open.lastActiveAt.timeIntervalSince1970
        pendingWrites.append((
            RadarStoreQueries.closeIncident,
            [
                .double(lastActive),
                .double(lastActive),
                .double(open.peak.score),
                .int64(Int64(clamping: open.peak.memoryBytes)),
                .text(open.id.uuidString)
            ]
        ))
    }

    /// Open rows, and rows closed recently enough to reopen. Open rows the
    /// previous run left behind close at their last sighting.
    private func load(now: Date) throws -> Episodes {
        var openRows: [(signatureID: String, incident: OpenIncident)] = []
        var closedRows: [(signatureID: String, incident: ClosedIncident)] = []
        let cutoff = now.addingTimeInterval(-Self.reopenWindow)
        try db.query(RadarStoreQueries.loadEpisodes, [.double(cutoff.timeIntervalSince1970)]) { row in
            guard let id = row.string(0).flatMap(UUID.init(uuidString:)), let signatureID = row.string(1) else {
                return
            }
            let peak = Peak(
                level: GhostLevel.allCases.first { $0.label == row.string(2) } ?? .hot,
                score: row.double(3),
                memoryBytes: row.bytes(4)
            )
            if row.isNull(6) {
                let lastSeen = row.date(5)
                openRows.append((signatureID, OpenIncident(id: id, peak: peak, lastActiveAt: lastSeen, lastWrittenAt: lastSeen)))
            } else {
                closedRows.append((signatureID, ClosedIncident(id: id, resolvedAt: row.date(6), peak: peak)))
            }
        }

        var episodes = Episodes()
        for (signatureID, open) in openRows.sorted(by: { $0.incident.lastActiveAt > $1.incident.lastActiveAt }) {
            if now.timeIntervalSince(open.lastActiveAt) < Self.closeAfter, episodes.open[signatureID] == nil {
                episodes.open[signatureID] = open
            } else {
                queueClose(open)
                closedRows.append((signatureID, ClosedIncident(id: open.id, resolvedAt: open.lastActiveAt, peak: open.peak)))
            }
        }
        for (signatureID, closed) in closedRows where closed.resolvedAt >= cutoff && episodes.open[signatureID] == nil {
            if let newer = episodes.recentlyClosed[signatureID], newer.resolvedAt >= closed.resolvedAt {
                continue
            }
            episodes.recentlyClosed[signatureID] = closed
        }
        return episodes
    }
}
