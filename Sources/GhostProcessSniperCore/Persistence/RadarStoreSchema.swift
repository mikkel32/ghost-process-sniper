import Foundation

enum RadarStoreSchema {
    static let migrationStatements = [
        "PRAGMA journal_mode = WAL",
        "PRAGMA synchronous = NORMAL",
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

    static let recentForecasts = """
        SELECT signature_id, state, confidence, eta_seconds, why_now, generated_at
        FROM forecasts
        ORDER BY generated_at DESC
        LIMIT ?
        """

    static let recentPredictiveAlerts = """
        SELECT id, signature_id, state, message, created_at
        FROM predictive_alerts
        ORDER BY created_at DESC
        LIMIT ?
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

    static let killHistorySummary = """
        SELECT COUNT(*),
               AVG(CASE WHEN survivor_count = 0 AND forced_count = 0 THEN 1.0 ELSE 0.0 END),
               AVG(CASE WHEN forced_count > 0 THEN 1.0 ELSE 0.0 END),
               AVG(CASE WHEN survivor_count > 0 THEN 1.0 ELSE 0.0 END),
               AVG(realized_memory_bytes),
               SUM(denial_count)
        FROM kill_outcome_history
        WHERE signature_id = ?
        """

    static let killStrategyHistoryBySignatureAndKind = """
        SELECT COUNT(*),
               AVG(CASE WHEN survivor_count = 0 AND forced_count = 0 THEN 1.0 ELSE 0.0 END),
               AVG(CASE WHEN forced_count > 0 THEN 1.0 ELSE 0.0 END),
               AVG(CASE WHEN survivor_count > 0 THEN 1.0 ELSE 0.0 END),
               AVG(realized_memory_bytes),
               SUM(denial_count)
        FROM kill_strategy_history
        WHERE signature_id = ? OR dev_kind = ?
        """

    static let killCalibration = """
        SELECT signature_id, dev_kind, strategy, operation_count, graceful_success_rate,
               force_rate, survivor_rate, average_grace_seconds, reclaim_accuracy,
               denial_penalty, updated_at
        FROM kill_calibration_aggregates
        WHERE id = ?
        LIMIT 1
        """
}
