import Foundation
import SQLite3

enum SQLiteValue {
    case text(String)
    case double(Double)
    case int64(Int64)
    case null
}

struct SQLiteAddedColumn: Sendable {
    let table: String
    let column: String
    let definition: String
}

/// One schema version. SQLite has no ADD COLUMN IF NOT EXISTS, so columns
/// added to a table after it first shipped are listed separately.
struct SQLiteMigration: Sendable {
    let version: Int32
    let statements: [String]
    var addedColumns: [SQLiteAddedColumn] = []
}

struct SQLiteRow {
    let statement: OpaquePointer

    func string(_ index: Int32) -> String? {
        SQLiteDatabase.columnString(statement, index)
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func bytes(_ index: Int32) -> UInt64 {
        UInt64(max(0, sqlite3_column_int64(statement, index)))
    }

    func date(_ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}

/// Owns one SQLite connection and its prepared statements. Deliberately not
/// Sendable: the store actor that creates it is its only user.
final class SQLiteDatabase {
    let url: URL
    private let busyTimeoutMilliseconds: Int32
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private(set) var lastResultCode: Int32 = SQLITE_OK

    init(url: URL, busyTimeoutMilliseconds: Int32 = 2_000) {
        self.url = url
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }

    deinit {
        close()
    }

    var isOpen: Bool {
        handle != nil
    }

    /// Corrupt or foreign files cannot be repaired in place; the caller moves
    /// them aside instead of failing on every launch.
    var lastFailureIsCorruption: Bool {
        let primary = lastResultCode & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    func open() throws {
        guard handle == nil else {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            lastResultCode = code
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw RadarStoreError.openFailed(message)
        }
        handle = opened
        do {
            // A second instance or a SQLite browser may hold the lock briefly;
            // wait for it instead of failing the flush outright.
            sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA synchronous = NORMAL")
            // A burst of writes may grow the WAL; truncate it back after
            // checkpoints instead of keeping the high-water mark on disk.
            try exec("PRAGMA journal_size_limit = 4194304")
        } catch {
            close()
            throw error
        }
    }

    /// Applies every migration newer than `PRAGMA user_version`, each in its
    /// own transaction, and returns the versions it applied.
    @discardableResult
    func migrate(_ migrations: [SQLiteMigration]) throws -> [Int32] {
        let current = try userVersion()
        var applied: [Int32] = []
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            try transaction {
                for sql in migration.statements {
                    try exec(sql)
                }
                for added in migration.addedColumns {
                    if try !hasColumn(added.column, in: added.table) {
                        try exec("ALTER TABLE \(added.table) ADD COLUMN \(added.column) \(added.definition)")
                    }
                }
                try exec("PRAGMA user_version = \(migration.version)")
            }
            applied.append(migration.version)
        }
        return applied
    }

    func userVersion() throws -> Int32 {
        var version: Int32 = 0
        try query("PRAGMA user_version") { row in
            version = Int32(truncatingIfNeeded: row.int64(0))
        }
        return version
    }

    func hasTables() throws -> Bool {
        try string("SELECT name FROM sqlite_master WHERE type = 'table' LIMIT 1") != nil
    }

    func hasColumn(_ column: String, in table: String) throws -> Bool {
        var found = false
        try query("PRAGMA table_info(\(table))") { row in
            if row.string(1) == column {
                found = true
            }
        }
        return found
    }

    func close() {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        statements.removeAll()
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    /// Moves the database and its WAL/SHM files aside so a fresh file can be
    /// created. Returns the new location of the main file.
    @discardableResult
    func quarantineFiles(at date: Date) -> URL {
        close()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).corrupt-\(formatter.string(from: date)).sqlite")
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            let target = URL(fileURLWithPath: destination.path + suffix)
            try? fileManager.removeItem(at: target)
            if (try? fileManager.moveItem(at: source, to: target)) == nil {
                try? fileManager.removeItem(at: source)
            }
        }
        return destination
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs SQL that may contain several statements or return rows it does
    /// not need (pragmas, DDL). Not cached.
    func exec(_ sql: String) throws {
        let connection = try connection()
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(connection, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            lastResultCode = code
            let text = message.map { String(cString: $0) } ?? "unknown sqlite error"
            if let message {
                sqlite3_free(message)
            }
            throw RadarStoreError.sqlite(text)
        }
    }

    func execute(_ sql: String, _ values: SQLiteValue...) throws {
        try execute(sql, values: values)
    }

    func execute(_ sql: String, values: [SQLiteValue]) throws {
        let statement = try statement(sql)
        defer { release(statement) }
        bind(values, to: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw failure(code)
        }
    }

    /// Steps a cached statement. `row` must not re-run the same SQL, because
    /// that would reset the statement being iterated.
    func query(_ sql: String, _ values: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        let statement = try statement(sql)
        // Resetting ends the implicit read transaction, so an idle cached
        // statement never pins the WAL.
        defer { release(statement) }
        bind(values, to: statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try row(SQLiteRow(statement: statement))
            } else if code == SQLITE_DONE {
                return
            } else {
                throw failure(code)
            }
        }
    }

    func string(_ sql: String, _ values: [SQLiteValue] = []) throws -> String? {
        var result: String?
        try query(sql, values) { row in
            if result == nil {
                result = row.string(0)
            }
        }
        return result
    }

    var changes: Int {
        handle.map { Int(sqlite3_changes($0)) } ?? 0
    }

    /// Rows inserted, updated or deleted since the connection opened.
    var totalChanges: Int {
        handle.map { Int(sqlite3_total_changes($0)) } ?? 0
    }

    /// Cached per SQL text; reused with its bindings cleared.
    func statement(_ sql: String) throws -> OpaquePointer {
        let connection = try connection()
        if let cached = statements[sql] {
            release(cached)
            return cached
        }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw failure(code)
        }
        statements[sql] = statement
        return statement
    }

    /// An uncached statement the caller must finalize.
    func prepare(_ sql: String) throws -> OpaquePointer? {
        let connection = try connection()
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard code == SQLITE_OK else {
            throw failure(code)
        }
        return statement
    }

    static func bind(_ value: SQLiteValue, to statement: OpaquePointer?, index: Int32) {
        switch value {
        case .text(let text):
            sqlite3_bind_text(statement, index, text, -1, transient)
        case .double(let value):
            sqlite3_bind_double(statement, index, value)
        case .int64(let value):
            sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case .null:
            sqlite3_bind_null(statement, index)
        }
    }

    static func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    /// `IN (...)` lists are padded to a few fixed sizes so the statement cache
    /// stays small; the extra slots are bound to NULL, which never matches.
    static func placeholderCount(for count: Int) -> Int {
        var size = 16
        while size < count {
            size *= 2
        }
        return size
    }

    static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            Self.bind(value, to: statement, index: Int32(offset + 1))
        }
    }

    private func release(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func connection() throws -> OpaquePointer {
        guard let handle else {
            throw RadarStoreError.sqlite("database is not open")
        }
        return handle
    }

    private func failure(_ code: Int32) -> RadarStoreError {
        lastResultCode = code
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
        return .sqlite(message)
    }
}
