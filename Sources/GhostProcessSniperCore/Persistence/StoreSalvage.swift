import Foundation

/// What the user chose, carried from a file found corrupt after open into
/// its fresh replacement. Rows the damage made unreadable stay behind.
struct StoreSalvage {
    private static let settingsKey = "thresholds"
    private let settings: [(key: String, json: String, updatedAt: Double)]
    private let rules: [(id: String, json: String, createdAt: Double)]

    /// `knownSettingsJSON` is what the store last read or wrote; it wins
    /// over a damaged row and stands in for one that cannot be read.
    init(readingFrom db: SQLiteDatabase, knownSettingsJSON: String?) {
        // A read can fail part way through; keep the rows it returned.
        var settings: [(key: String, json: String, updatedAt: Double)] = []
        try? db.query("SELECT key, json, updated_at FROM settings") { row in
            if let key = row.string(0), let json = row.string(1) {
                settings.append((key, json, row.double(2)))
            }
        }
        if let knownSettingsJSON {
            settings.removeAll { $0.key == Self.settingsKey }
            settings.append((Self.settingsKey, knownSettingsJSON, Date().timeIntervalSince1970))
        }
        var rules: [(id: String, json: String, createdAt: Double)] = []
        try? db.query("SELECT id, json, created_at FROM rules") { row in
            if let id = row.string(0), let json = row.string(1) {
                rules.append((id, json, row.double(2)))
            }
        }
        self.settings = settings
        self.rules = rules
    }

    /// Returns the restored threshold settings JSON, or nil when there were
    /// none or the write failed.
    func restore(into db: SQLiteDatabase) -> String? {
        do {
            try db.transaction {
                for row in settings {
                    try db.execute(
                        "INSERT OR REPLACE INTO settings(key, json, updated_at) VALUES(?, ?, ?)",
                        .text(row.key), .text(row.json), .double(row.updatedAt)
                    )
                }
                for row in rules {
                    try db.execute(
                        "INSERT OR REPLACE INTO rules(id, json, created_at) VALUES(?, ?, ?)",
                        .text(row.id), .text(row.json), .double(row.createdAt)
                    )
                }
            }
        } catch {
            RadarLogger.store.error("Restoring settings and rules from the corrupt store failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return settings.first { $0.key == Self.settingsKey }?.json
    }
}
