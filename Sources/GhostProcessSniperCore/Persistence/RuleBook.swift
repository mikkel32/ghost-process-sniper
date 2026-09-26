import Foundation

/// Stored rules and the composed built-in + stored list the radar context
/// uses. Both are cached; the composed list only until its earliest expiry, so
/// a snooze ends on time instead of at the next rule edit.
final class RuleBook {
    private let db: SQLiteDatabase
    private let codec: StoreCodec
    private var cachedStored: [RadarRule]?
    private var cachedKey: String?
    private var cachedComposed: [RadarRule] = []
    private var nextExpiry: Date?
    private var revision = 0
    private(set) var cacheHitCount = 0

    init(db: SQLiteDatabase, codec: StoreCodec) {
        self.db = db
        self.codec = codec
    }

    static func isExpired(_ rule: RadarRule, at now: Date) -> Bool {
        rule.expiresAt.map { $0 <= now } ?? false
    }

    /// Every stored rule, expired or not; callers filter with their own clock.
    func stored() throws -> [RadarRule] {
        if let cachedStored {
            cacheHitCount += 1
            return cachedStored
        }
        var rules: [RadarRule] = []
        try db.query("SELECT json FROM rules ORDER BY created_at DESC") { row in
            if let rule = codec.decode(RadarRule.self, from: row.string(0)) {
                rules.append(rule)
            }
        }
        cachedStored = rules
        return rules
    }

    func composed(settings: ThresholdSettings, now: Date) throws -> [RadarRule] {
        let key = "\(revision)|\(settings.memoryBytes)|\(Int(settings.cpuPercent.rounded()))|\(Int(settings.leakVelocityMegabytesPerMinute.rounded()))|\(settings.radarMode.rawValue)"
        if cachedKey == key, nextExpiry.map({ now < $0 }) ?? true {
            cacheHitCount += 1
            return cachedComposed
        }
        let composed = try (RadarRule.builtIns(settings: settings) + stored())
            .filter { !Self.isExpired($0, at: now) }
        cachedKey = key
        cachedComposed = composed
        nextExpiry = composed.compactMap(\.expiresAt).min()
        return composed
    }

    func save(_ rule: RadarRule) throws {
        try db.execute(
            "INSERT INTO rules(id, json, created_at) VALUES(?, ?, ?) " +
            "ON CONFLICT(id) DO UPDATE SET json = excluded.json",
            .text(rule.id.uuidString),
            .text(try codec.encode(rule)),
            .double(rule.createdAt.timeIntervalSince1970)
        )
        invalidate()
    }

    func delete(id: UUID) throws {
        try db.execute("DELETE FROM rules WHERE id = ?", .text(id.uuidString))
        invalidate()
    }

    func pruneExpired(now: Date) throws {
        // Rules encode dates as seconds since 1970.
        try db.execute(
            "DELETE FROM rules WHERE json_extract(json, '$.expiresAt') IS NOT NULL AND json_extract(json, '$.expiresAt') < ?",
            .double(now.timeIntervalSince1970)
        )
        if db.changes > 0 {
            invalidate()
        }
    }

    private func invalidate() {
        revision += 1
        cachedStored = nil
        cachedKey = nil
        cachedComposed.removeAll(keepingCapacity: true)
        nextExpiry = nil
    }
}
