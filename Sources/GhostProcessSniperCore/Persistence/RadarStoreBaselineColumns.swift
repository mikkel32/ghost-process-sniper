import Foundation
import SQLite3

/// Baseline columns added after the table first shipped, upgraded in place
/// on open. Missing columns get defaults that mark old rows for relearning.
enum RadarStoreBaselineColumns {
    static let added: [(name: String, definition: String)] = [
        ("measurement_version", "INTEGER NOT NULL DEFAULT 0"),
        ("memory_variance", "REAL NOT NULL DEFAULT 0"),
        ("cpu_variance", "REAL NOT NULL DEFAULT 0"),
        ("observed_seconds", "REAL NOT NULL DEFAULT 0"),
        ("session_count", "INTEGER NOT NULL DEFAULT 1")
    ]

    static func upgrade(_ handle: OpaquePointer?) throws {
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(baselines)", -1, &columns, nil) == SQLITE_OK else {
            throw RadarStoreError.sqlite("Cannot inspect baseline schema")
        }
        var existing = Set<String>()
        while sqlite3_step(columns) == SQLITE_ROW {
            if let name = sqlite3_column_text(columns, 1) {
                existing.insert(String(cString: name))
            }
        }
        sqlite3_finalize(columns)
        for column in added where !existing.contains(column.name) {
            let sql = "ALTER TABLE baselines ADD COLUMN \(column.name) \(column.definition)"
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw RadarStoreError.sqlite("Cannot upgrade baseline column \(column.name)")
            }
        }
    }
}
