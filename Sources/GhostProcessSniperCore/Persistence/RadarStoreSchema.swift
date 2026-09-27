import Foundation

enum RadarStoreSchema {
    /// The version that drops the write-only tables; the store backs the file
    /// up before migrating past it.
    static let slimVersion: Int32 = 3

    /// The version that rebuilds the kill learning tables (held force,
    /// outcome posteriors).
    static let killLearningVersion: Int32 = 4

    /// The version that adds the learned-baseline statistics (variance,
    /// observed time, sessions). Old rows get defaults that mark them for
    /// relearning.
    static let baselineStatisticsVersion: Int32 = 5

    /// The version that adds each day's energy per app and job.
    static let energyHistoryVersion: Int32 = 6

    /// Append new versions; never edit a version that has shipped.
    static let migrations = [
        // Version 1 is the schema from before versioning. Its statements are
        // idempotent, so an unversioned file with these tables is stamped v1.
        SQLiteMigration(
            version: 1,
            statements: migrationStatements,
            addedColumns: [
                SQLiteAddedColumn(table: "baselines", column: "measurement_version", definition: "INTEGER NOT NULL DEFAULT 0")
            ]
        ),
        // Recurrence counts only resolved incidents, so the index must cover
        // resolved_at as well.
        SQLiteMigration(
            version: 2,
            statements: [
                "DROP INDEX IF EXISTS incidents_signature_started",
                "CREATE INDEX IF NOT EXISTS incidents_signature_started_resolved ON incidents(signature_id, started_at, resolved_at)"
            ]
        ),
        // Tables nothing reads, and indexes no query uses. The kill detail
        // tables stay until kill learning stops writing them.
        SQLiteMigration(
            version: slimVersion,
            statements: [
                "DROP TABLE IF EXISTS samples",
                "DROP TABLE IF EXISTS forecasts",
                "DROP TABLE IF EXISTS recommendation_history",
                "DROP TABLE IF EXISTS predictive_alerts",
                "DROP TABLE IF EXISTS actions",
                "DROP INDEX IF EXISTS kill_operations_signature_time",
                "DROP INDEX IF EXISTS kill_calibration_signature_kind_strategy"
            ]
        ),
        // Learning rows written before held force and real refusals were told
        // apart carry fake survivors and denials that locked families out of
        // stopping, and the calibration aggregates become outcome posteriors.
        // The three learning tables are rebuilt empty.
        SQLiteMigration(
            version: killLearningVersion,
            statements: killLearningTables.map { "DROP TABLE IF EXISTS \($0)" } + killLearningStatements
        ),
        SQLiteMigration(
            version: baselineStatisticsVersion,
            statements: [],
            addedColumns: [
                SQLiteAddedColumn(table: "baselines", column: "memory_variance", definition: "REAL NOT NULL DEFAULT 0"),
                SQLiteAddedColumn(table: "baselines", column: "cpu_variance", definition: "REAL NOT NULL DEFAULT 0"),
                SQLiteAddedColumn(table: "baselines", column: "observed_seconds", definition: "REAL NOT NULL DEFAULT 0"),
                SQLiteAddedColumn(table: "baselines", column: "session_count", definition: "INTEGER NOT NULL DEFAULT 1")
            ]
        ),
        // One row per local day and app or job, added to every few minutes.
        SQLiteMigration(
            version: energyHistoryVersion,
            statements: [
                """
                CREATE TABLE IF NOT EXISTS energy_days(
                    day TEXT NOT NULL,
                    group_key TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    application_path TEXT,
                    joules REAL NOT NULL DEFAULT 0,
                    wakeups REAL NOT NULL DEFAULT 0,
                    disk_bytes REAL NOT NULL DEFAULT 0,
                    cpu_seconds REAL NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(day, group_key)
                ) WITHOUT ROWID
                """
            ]
        )
    ]

    /// Tables whose rows expire `incidentRetention` after `created_at`.
    static let createdAtRetentionTables = [
        "kill_operations", "kill_operation_events", "kill_outcome_history",
        "kill_strategy_history", "kill_signal_outcomes", "kill_graph_deltas",
        "kill_reclaim_calibration", "kill_exit_events"
    ]

    /// Connection pragmas (WAL, synchronous, busy timeout) are applied by
    /// SQLiteDatabase.open, because WAL cannot be enabled inside a transaction.
    static let migrationStatements = [
        """
        CREATE TABLE IF NOT EXISTS settings(
            key TEXT PRIMARY KEY NOT NULL,
            json TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS baselines(
            signature_id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL,
            canonical_path TEXT NOT NULL,
            command_fingerprint TEXT NOT NULL,
            sample_count INTEGER NOT NULL,
            mean_memory_bytes REAL NOT NULL,
            peak_memory_bytes INTEGER NOT NULL,
            mean_cpu_percent REAL NOT NULL,
            peak_cpu_percent REAL NOT NULL,
            mean_leak_velocity REAL NOT NULL,
            incident_count INTEGER NOT NULL,
            first_seen_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            measurement_version INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS samples(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            signature_id TEXT NOT NULL,
            family_name TEXT NOT NULL,
            level TEXT NOT NULL,
            score REAL NOT NULL,
            memory_bytes INTEGER NOT NULL,
            cpu_percent REAL NOT NULL,
            leak_velocity REAL NOT NULL,
            sampled_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS samples_signature_time ON samples(signature_id, sampled_at)",
        "CREATE INDEX IF NOT EXISTS samples_time ON samples(sampled_at)",
        """
        CREATE TABLE IF NOT EXISTS incidents(
            id TEXT PRIMARY KEY NOT NULL,
            signature_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            canonical_path TEXT NOT NULL,
            command_fingerprint TEXT NOT NULL,
            family_name TEXT NOT NULL,
            level TEXT NOT NULL,
            max_score REAL NOT NULL,
            memory_bytes INTEGER NOT NULL,
            cpu_percent REAL NOT NULL,
            leak_velocity REAL NOT NULL,
            reasons_json TEXT NOT NULL,
            started_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            resolved_at REAL,
            occurrence_count INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS incidents_signature_active ON incidents(signature_id, resolved_at)",
        // Covers recurrence counts without fetching every matching incident row.
        "CREATE INDEX IF NOT EXISTS incidents_signature_started ON incidents(signature_id, started_at)",
        "CREATE INDEX IF NOT EXISTS incidents_resolved_coalesce ON incidents(COALESCE(resolved_at, last_seen_at) DESC)",
        "CREATE INDEX IF NOT EXISTS incidents_resolved_time ON incidents(resolved_at)",
        """
        CREATE TABLE IF NOT EXISTS rules(
            id TEXT PRIMARY KEY NOT NULL,
            json TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS rules_created ON rules(created_at)",
        """
        CREATE TABLE IF NOT EXISTS actions(
            id TEXT PRIMARY KEY NOT NULL,
            signature_id TEXT,
            kind TEXT NOT NULL,
            summary TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS actions_created ON actions(created_at)",
        """
        CREATE TABLE IF NOT EXISTS forecasts(
            signature_id TEXT PRIMARY KEY NOT NULL,
            state TEXT NOT NULL,
            confidence REAL NOT NULL,
            eta_seconds REAL,
            why_now TEXT NOT NULL,
            projected_memory_bytes INTEGER NOT NULL,
            projected_cpu_percent REAL NOT NULL,
            recurrence_risk REAL NOT NULL,
            stale_likelihood REAL NOT NULL,
            generated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS forecasts_state_time ON forecasts(state, generated_at)",
        """
        CREATE TABLE IF NOT EXISTS predictive_alerts(
            id TEXT PRIMARY KEY NOT NULL,
            signature_id TEXT NOT NULL,
            state TEXT NOT NULL,
            message TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS predictive_alerts_signature_time ON predictive_alerts(signature_id, created_at)",
        "CREATE INDEX IF NOT EXISTS predictive_alerts_created ON predictive_alerts(created_at)",
        """
        CREATE TABLE IF NOT EXISTS recommendation_history(
            id TEXT PRIMARY KEY NOT NULL,
            signature_id TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            action TEXT NOT NULL,
            confidence REAL NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS recommendation_history_signature_time ON recommendation_history(signature_id, created_at)",
        "CREATE INDEX IF NOT EXISTS recommendation_history_created ON recommendation_history(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_operations(
            id TEXT PRIMARY KEY NOT NULL,
            signature_id TEXT,
            display_name TEXT NOT NULL,
            root_pid INTEGER NOT NULL,
            summary TEXT NOT NULL,
            estimated_memory_bytes INTEGER NOT NULL,
            realized_memory_bytes INTEGER NOT NULL,
            graceful_count INTEGER NOT NULL,
            forced_count INTEGER NOT NULL,
            survivor_count INTEGER NOT NULL,
            locked_count INTEGER NOT NULL,
            stale_count INTEGER NOT NULL,
            recycled_count INTEGER NOT NULL,
            duration_ms REAL NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_operations_created ON kill_operations(created_at DESC)",
        "CREATE INDEX IF NOT EXISTS kill_operations_signature_time ON kill_operations(signature_id, created_at DESC)",
        """
        CREATE TABLE IF NOT EXISTS kill_operation_events(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            pid INTEGER,
            signal_name TEXT,
            target_state TEXT,
            message TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_operation_events_operation_time ON kill_operation_events(operation_id, created_at)",
        "CREATE INDEX IF NOT EXISTS kill_operation_events_created ON kill_operation_events(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_outcome_history(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            signature_id TEXT,
            strategy TEXT NOT NULL,
            scope TEXT NOT NULL,
            graceful_count INTEGER NOT NULL,
            forced_count INTEGER NOT NULL,
            survivor_count INTEGER NOT NULL,
            locked_count INTEGER NOT NULL,
            realized_memory_bytes INTEGER NOT NULL,
            denial_count INTEGER NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_outcome_history_signature_time ON kill_outcome_history(signature_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS kill_outcome_history_created ON kill_outcome_history(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_strategy_history(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            signature_id TEXT,
            dev_kind TEXT,
            strategy TEXT NOT NULL,
            scope TEXT NOT NULL,
            graceful_count INTEGER NOT NULL,
            forced_count INTEGER NOT NULL,
            survivor_count INTEGER NOT NULL,
            locked_count INTEGER NOT NULL,
            realized_memory_bytes INTEGER NOT NULL,
            denial_count INTEGER NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_strategy_history_signature_kind_time ON kill_strategy_history(signature_id, dev_kind, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS kill_strategy_history_created ON kill_strategy_history(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_signal_outcomes(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            pid INTEGER NOT NULL,
            signal_name TEXT NOT NULL,
            stage TEXT NOT NULL,
            succeeded INTEGER NOT NULL,
            message TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_signal_outcomes_operation ON kill_signal_outcomes(operation_id)",
        "CREATE INDEX IF NOT EXISTS kill_signal_outcomes_created ON kill_signal_outcomes(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_graph_deltas(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            summary TEXT NOT NULL,
            preview_count INTEGER NOT NULL,
            confirm_count INTEGER NOT NULL,
            survivor_count INTEGER NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_graph_deltas_operation ON kill_graph_deltas(operation_id)",
        "CREATE INDEX IF NOT EXISTS kill_graph_deltas_created ON kill_graph_deltas(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_reclaim_calibration(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            signature_id TEXT,
            dev_kind TEXT,
            strategy TEXT NOT NULL,
            estimated_memory_bytes INTEGER NOT NULL,
            realized_memory_bytes INTEGER NOT NULL,
            calibrated_memory_bytes INTEGER NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_reclaim_calibration_signature_time ON kill_reclaim_calibration(signature_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS kill_reclaim_calibration_created ON kill_reclaim_calibration(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_exit_events(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            pid INTEGER NOT NULL,
            kind TEXT NOT NULL,
            message TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_exit_events_operation ON kill_exit_events(operation_id)",
        "CREATE INDEX IF NOT EXISTS kill_exit_events_created ON kill_exit_events(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_calibration_aggregates(
            id TEXT PRIMARY KEY NOT NULL,
            signature_id TEXT,
            dev_kind TEXT,
            strategy TEXT NOT NULL,
            operation_count INTEGER NOT NULL,
            graceful_success_rate REAL NOT NULL,
            force_rate REAL NOT NULL,
            survivor_rate REAL NOT NULL,
            average_grace_seconds REAL NOT NULL,
            reclaim_accuracy REAL NOT NULL,
            denial_penalty REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_calibration_signature_kind_strategy ON kill_calibration_aggregates(signature_id, dev_kind, strategy)"
    ]

    static let killLearningTables = ["kill_outcome_history", "kill_strategy_history", "kill_calibration_aggregates"]

    static let killLearningStatements = [
        """
        CREATE TABLE IF NOT EXISTS kill_outcome_history(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            signature_id TEXT,
            strategy TEXT NOT NULL,
            scope TEXT NOT NULL,
            graceful_count INTEGER NOT NULL,
            forced_count INTEGER NOT NULL,
            survivor_count INTEGER NOT NULL,
            locked_count INTEGER NOT NULL,
            realized_memory_bytes INTEGER NOT NULL,
            denial_count INTEGER NOT NULL,
            held_force INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_outcome_history_signature_time ON kill_outcome_history(signature_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS kill_outcome_history_created ON kill_outcome_history(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_strategy_history(
            id TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            signature_id TEXT,
            dev_kind TEXT,
            strategy TEXT NOT NULL,
            scope TEXT NOT NULL,
            graceful_count INTEGER NOT NULL,
            forced_count INTEGER NOT NULL,
            survivor_count INTEGER NOT NULL,
            locked_count INTEGER NOT NULL,
            realized_memory_bytes INTEGER NOT NULL,
            denial_count INTEGER NOT NULL,
            held_force INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_strategy_history_signature_time ON kill_strategy_history(signature_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS kill_strategy_history_created ON kill_strategy_history(created_at)",
        """
        CREATE TABLE IF NOT EXISTS kill_calibration_aggregates(
            id TEXT PRIMARY KEY NOT NULL,
            signature_id TEXT,
            dev_kind TEXT,
            strategy TEXT NOT NULL,
            operation_count INTEGER NOT NULL,
            clean_count INTEGER NOT NULL,
            clean_weight REAL NOT NULL,
            total_weight REAL NOT NULL,
            latency_buckets TEXT NOT NULL,
            respawn_weight REAL NOT NULL,
            censored_run INTEGER NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS kill_calibration_signature_kind_strategy ON kill_calibration_aggregates(signature_id, dev_kind, strategy)"
    ]
}

enum RadarStoreQueries {
    static let recentIncidents = """
        SELECT id, signature_id, display_name, canonical_path, command_fingerprint, family_name,
               level, max_score, memory_bytes, cpu_percent, leak_velocity, reasons_json,
               started_at, last_seen_at, resolved_at, occurrence_count
        FROM incidents
        ORDER BY COALESCE(resolved_at, last_seen_at) DESC
        LIMIT ?
        """

    static let loadEpisodes = """
        SELECT id, signature_id, level, max_score, memory_bytes, last_seen_at, resolved_at
        FROM incidents
        WHERE resolved_at IS NULL OR resolved_at >= ?
        """

    static let insertIncident = """
        INSERT INTO incidents(id, signature_id, display_name, canonical_path, command_fingerprint, family_name,
                              level, max_score, memory_bytes, cpu_percent, leak_velocity, reasons_json,
                              started_at, last_seen_at, resolved_at, occurrence_count)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 1)
        """

    static let refreshIncident = """
        UPDATE incidents
        SET level = ?, max_score = MAX(max_score, ?), memory_bytes = MAX(memory_bytes, ?),
            cpu_percent = ?, leak_velocity = ?, last_seen_at = ?
        WHERE id = ?
        """

    static let escalateIncident = """
        UPDATE incidents
        SET level = ?, max_score = MAX(max_score, ?), memory_bytes = MAX(memory_bytes, ?),
            cpu_percent = ?, leak_velocity = ?, last_seen_at = ?, reasons_json = ?
        WHERE id = ?
        """

    static let reopenIncident = """
        UPDATE incidents
        SET resolved_at = NULL, occurrence_count = occurrence_count + 1, last_seen_at = ?, level = ?,
            max_score = MAX(max_score, ?), memory_bytes = MAX(memory_bytes, ?), cpu_percent = ?, leak_velocity = ?
        WHERE id = ?
        """

    static let closeIncident = """
        UPDATE incidents
        SET resolved_at = ?, last_seen_at = MAX(last_seen_at, ?),
            max_score = MAX(max_score, ?), memory_bytes = MAX(memory_bytes, ?)
        WHERE id = ?
        """

    static let recentKillOperations = """
        SELECT id, signature_id, display_name, root_pid, summary, estimated_memory_bytes,
               realized_memory_bytes, graceful_count, forced_count, survivor_count,
               locked_count, stale_count, recycled_count, duration_ms, created_at
        FROM kill_operations
        ORDER BY created_at DESC
        LIMIT ?
        """

    static let recentKillEvents = """
        SELECT id, operation_id, kind, pid, signal_name, target_state, message, created_at
        FROM kill_operation_events
        WHERE operation_id = ?
        ORDER BY created_at ASC
        LIMIT ?
        """

    /// The latest 20 stops of one family within 30 days. Survivors the user
    /// chose to keep (held force) are not failures of the stop.
    static let killHistorySummary = historySummary(from: "kill_outcome_history")
    static let killStrategyHistory = historySummary(from: "kill_strategy_history")

    private static func historySummary(from table: String) -> String {
        """
        SELECT COUNT(*),
               AVG(CASE WHEN survivor_count = 0 AND forced_count = 0 THEN 1.0 ELSE 0.0 END),
               AVG(CASE WHEN forced_count > 0 THEN 1.0 ELSE 0.0 END),
               AVG(CASE WHEN survivor_count > 0 AND held_force = 0 THEN 1.0 ELSE 0.0 END),
               AVG(realized_memory_bytes),
               SUM(denial_count)
        FROM (SELECT * FROM \(table)
              WHERE signature_id = ? AND created_at >= ?
              ORDER BY created_at DESC
              LIMIT 20)
        """
    }

    /// Outcome posteriors: one row per family and strategy (no dev kind),
    /// one per kind and strategy (no signature) as the family's prior.
    static let killOutcomePosteriorColumns = """
        signature_id, dev_kind, strategy, operation_count, clean_count, clean_weight, total_weight,
        latency_buckets, respawn_weight, censored_run, updated_at
        """

    static let killOutcomePosterior = """
        SELECT \(killOutcomePosteriorColumns)
        FROM kill_calibration_aggregates
        WHERE id = ?
        LIMIT 1
        """

    static let killOutcomeHistory = """
        SELECT \(killOutcomePosteriorColumns)
        FROM kill_calibration_aggregates
        WHERE (signature_id = ? AND dev_kind IS NULL) OR (signature_id IS NULL AND dev_kind = ?)
        """
}
