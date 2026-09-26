import Foundation
import SQLite3

/// Kill operations and the outcome history that tunes future stops.
extension RadarStore {
    /// - Parameter learnsFromOutcome: false when the stop was of another
    ///   process than `family`, such as its supervisor: it is audited, but
    ///   says nothing about how the family stops.
    public func recordKillOperation(
        report: KillReport,
        family: ProcessFamily?,
        learnsFromOutcome: Bool = true,
        at date: Date = Date()
    ) throws {
        let record = KillOperationRecord(report: report, family: family, createdAt: date)
        try transaction {
            try execute(
                """
                INSERT INTO kill_operations(id, signature_id, display_name, root_pid, summary,
                                            estimated_memory_bytes, realized_memory_bytes,
                                            graceful_count, forced_count, survivor_count,
                                            locked_count, stale_count, recycled_count,
                                            duration_ms, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                .text(record.id.rawValue),
                record.signatureID.map { .text($0) } ?? .null,
                .text(record.displayName),
                .int64(Int64(record.rootPID)),
                .text(record.summary),
                .int64(Int64(clamping: record.estimatedMemoryReclaimBytes)),
                .int64(Int64(clamping: record.realizedMemoryReclaimBytes)),
                .int64(Int64(record.gracefulCount)),
                .int64(Int64(record.forcedCount)),
                .int64(Int64(record.survivorCount)),
                .int64(Int64(record.lockedCount)),
                .int64(Int64(record.staleCount)),
                .int64(Int64(record.recycledCount)),
                .double(record.durationMilliseconds),
                .double(record.createdAt.timeIntervalSince1970)
            )
            for event in report.eventHistory {
                try insertKillEvent(event)
            }
            try insertKillSignalOutcomes(report: report, createdAt: date)
            try insertKillGraphDeltas(report: report, createdAt: date)
            try insertKillExitEvents(report: report)
            // Refused, expired and inspect-only stops sent nothing; they say
            // nothing about how the family stops and stay audit-only.
            guard !report.attempts.isEmpty, learnsFromOutcome else { return }
            let devKind = family?.classification?.kind.rawValue
            try insertKillOutcomeHistory(report: report, signatureID: record.signatureID, createdAt: date)
            try insertKillStrategyHistory(report: report, signatureID: record.signatureID, devKind: devKind, createdAt: date)
            try insertKillReclaimCalibration(report: report, signatureID: record.signatureID, devKind: devKind, createdAt: date)
            try upsertKillOutcomePosteriors(report: report, signatureID: record.signatureID, devKind: devKind, createdAt: date)
        }
        lastKillOperationSummary = "\(record.displayName): \(record.summary)"
    }

    public func recentKillOperations(limit: Int = 20) throws -> [KillOperationRecord] {
        let statement = try prepare(RadarStoreQueries.recentKillOperations)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var records: [KillOperationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(killOperation(from: statement))
        }
        return records
    }

    public func recentKillEvents(operationID: KillOperationID, limit: Int = 200) throws -> [KillOperationEvent] {
        let statement = try prepare(RadarStoreQueries.recentKillEvents)
        defer { sqlite3_finalize(statement) }
        bind(.text(operationID.rawValue), to: statement, index: 1)
        bind(.int64(Int64(limit)), to: statement, index: 2)

        var events: [KillOperationEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            events.append(killEvent(from: statement))
        }
        return events
    }

    /// How the family's recent stops went: its own latest 20 within 30 days.
    public func killHistorySummary(signatureID: String, now: Date = Date()) throws -> KillHistorySummary {
        try historySummary(RadarStoreQueries.killHistorySummary, signatureID: signatureID, now: now)
    }

    public func killStrategyHistory(signatureID: String, now: Date = Date()) throws -> KillHistorySummary {
        try historySummary(RadarStoreQueries.killStrategyHistory, signatureID: signatureID, now: now)
    }

    private func historySummary(_ sql: String, signatureID: String, now: Date) throws -> KillHistorySummary {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(.text(signatureID), to: statement, index: 1)
        bind(.double(now.addingTimeInterval(-Self.killHistoryWindow).timeIntervalSince1970), to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return .empty
        }
        let count = Int(sqlite3_column_int64(statement, 0))
        guard count > 0 else {
            return .empty
        }
        return KillHistorySummary(
            signatureID: signatureID,
            operationCount: count,
            gracefulSuccessRate: sqlite3_column_double(statement, 1),
            forceRate: sqlite3_column_double(statement, 2),
            survivorRate: sqlite3_column_double(statement, 3),
            averageReclaimBytes: UInt64(max(0, sqlite3_column_int64(statement, 4))),
            commonDenialCount: Int(sqlite3_column_int64(statement, 5))
        )
    }

    /// Outcome posteriors of a family and of its kind, per strategy.
    public func killOutcomeHistory(signatureID: String, devKind: String?) throws -> KillOutcomeHistory {
        let statement = try prepare(RadarStoreQueries.killOutcomeHistory)
        defer { sqlite3_finalize(statement) }
        bind(.text(signatureID), to: statement, index: 1)
        bind(devKind.map { .text($0) } ?? .null, to: statement, index: 2)
        var history = KillOutcomeHistory.empty
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let strategy = columnString(statement, 2).flatMap(KillStrategy.init(rawValue:)) else { continue }
            if columnString(statement, 0) != nil {
                history.signature[strategy] = outcomePosterior(from: statement)
            } else {
                history.kind[strategy] = outcomePosterior(from: statement)
            }
        }
        return history
    }

    /// Rows from the kill tables older than the retention window.
    func pruneKillOperations(before cutoff: Date) throws {
        let tables = ["kill_operations", "kill_operation_events", "kill_outcome_history", "kill_strategy_history",
                      "kill_signal_outcomes", "kill_graph_deltas", "kill_reclaim_calibration", "kill_exit_events"]
        for table in tables {
            try execute("DELETE FROM \(table) WHERE created_at < ?", .double(cutoff.timeIntervalSince1970))
        }
    }

    /// Learning rows written before held force and real refusals were told
    /// apart carry fake survivors and denials that locked families out of
    /// stopping, so a store from an older version rebuilds those tables.
    static func migrateKillLearning(_ handle: OpaquePointer?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw RadarStoreError.sqlite("Cannot read the store version")
        }
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
        sqlite3_finalize(statement)
        guard version < RadarStoreSchema.version else { return }
        let rebuild = RadarStoreSchema.killLearningTables.map { "DROP TABLE IF EXISTS \($0)" } +
            RadarStoreSchema.killLearningStatements + ["PRAGMA user_version = \(RadarStoreSchema.version)"]
        for sql in rebuild {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw RadarStoreError.sqlite("Cannot rebuild kill learning: \(String(cString: sqlite3_errmsg(handle)))")
            }
        }
    }

    public func killSignalOutcomeCount(operationID: KillOperationID) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM kill_signal_outcomes WHERE operation_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(.text(operationID.rawValue), to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func killGraphDeltaCount(operationID: KillOperationID) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM kill_graph_deltas WHERE operation_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(.text(operationID.rawValue), to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func killExitEventCount(operationID: KillOperationID) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM kill_exit_events WHERE operation_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(.text(operationID.rawValue), to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func exportKillDiagnostics(limit: Int = 8) throws -> String {
        let kills = try recentKillOperations(limit: limit)
        guard !kills.isEmpty else {
            return "Ghost Process Sniper Kill Diagnostics\nNo kill operations recorded yet."
        }
        var lines = ["Ghost Process Sniper Kill Diagnostics", "Generated \(Date().formatted())", ""]
        for record in kills {
            lines.append("\(record.displayName) - \(record.strategy.label) - \(record.scope.label)")
            lines.append("  root PID \(record.rootPID), duration \(Int(record.durationMilliseconds.rounded())) ms")
            lines.append("  term \(record.gracefulCount), force \(record.forcedCount), survivors \(record.survivorCount), locked \(record.lockedCount)")
            let signalCount = try killSignalOutcomeCount(operationID: record.id)
            let exitCount = try killExitEventCount(operationID: record.id)
            let deltaCount = try killGraphDeltaCount(operationID: record.id)
            lines.append("  kernel signals \(signalCount), exits \(exitCount), graph deltas \(deltaCount)")
            lines.append("  reclaim \(RadarFormat.bytes(record.realizedMemoryReclaimBytes)); \(record.summary)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func insertKillEvent(_ event: KillOperationEvent) throws {
        try execute(
            """
            INSERT OR REPLACE INTO kill_operation_events(id, operation_id, kind, pid, signal_name,
                                                         target_state, message, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """,
            .text(event.id.uuidString),
            .text(event.operationID.rawValue),
            .text(event.kind.rawValue),
            event.pid.map { .int64(Int64($0)) } ?? .null,
            event.signalName.map { .text($0) } ?? .null,
            event.targetState.map { .text($0.rawValue) } ?? .null,
            .text(event.message),
            .double(event.createdAt.timeIntervalSince1970)
        )
    }

    private func insertKillOutcomeHistory(report: KillReport, signatureID: String?, createdAt: Date) throws {
        try execute(
            """
            INSERT INTO kill_outcome_history(id, operation_id, signature_id, strategy, scope,
                                             graceful_count, forced_count, survivor_count, locked_count,
                                             realized_memory_bytes, denial_count, held_force, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            .text(UUID().uuidString),
            .text(report.operationID.rawValue),
            signatureID.map { .text($0) } ?? .null,
            .text(report.strategyUsed.rawValue),
            .text(report.scopeUsed.rawValue),
            .int64(Int64(report.gracefulPIDs.count)),
            .int64(Int64(report.forcedPIDs.count)),
            .int64(Int64(report.survivorPIDs.count)),
            .int64(Int64(report.deniedPIDs.count)),
            .int64(Int64(clamping: report.realizedMemoryReclaimBytes)),
            .int64(Int64(report.signalDeniedPIDs.count)),
            .int64(report.skipForceRequested ? 1 : 0),
            .double(createdAt.timeIntervalSince1970)
        )
    }

    private func insertKillStrategyHistory(report: KillReport, signatureID: String?, devKind: String?, createdAt: Date) throws {
        try execute(
            """
            INSERT INTO kill_strategy_history(id, operation_id, signature_id, dev_kind, strategy, scope,
                                              graceful_count, forced_count, survivor_count, locked_count,
                                              realized_memory_bytes, denial_count, held_force, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            .text(UUID().uuidString),
            .text(report.operationID.rawValue),
            signatureID.map { .text($0) } ?? .null,
            devKind.map { .text($0) } ?? .null,
            .text(report.strategyUsed.rawValue),
            .text(report.scopeUsed.rawValue),
            .int64(Int64(report.gracefulPIDs.count)),
            .int64(Int64(report.forcedPIDs.count)),
            .int64(Int64(report.survivorPIDs.count)),
            .int64(Int64(report.deniedPIDs.count)),
            .int64(Int64(clamping: report.realizedMemoryReclaimBytes)),
            .int64(Int64(report.signalDeniedPIDs.count)),
            .int64(report.skipForceRequested ? 1 : 0),
            .double(createdAt.timeIntervalSince1970)
        )
    }

    private func insertKillSignalOutcomes(report: KillReport, createdAt: Date) throws {
        for attempt in report.attempts {
            try execute(
                """
                INSERT INTO kill_signal_outcomes(id, operation_id, pid, signal_name, stage,
                                                 succeeded, message, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """,
                .text(UUID().uuidString),
                .text(report.operationID.rawValue),
                .int64(Int64(attempt.pid)),
                .text(attempt.signalName),
                .text(attempt.stage),
                .int64(attempt.succeeded ? 1 : 0),
                .text(attempt.message),
                .double(createdAt.timeIntervalSince1970)
            )
        }
    }

    private func insertKillGraphDeltas(report: KillReport, createdAt: Date) throws {
        let delta = report.finalGraphDelta
        try execute(
            """
            INSERT INTO kill_graph_deltas(id, operation_id, summary, preview_count,
                                          confirm_count, survivor_count, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """,
            .text(UUID().uuidString),
            .text(report.operationID.rawValue),
            .text(delta.summary),
            .int64(Int64(delta.previewTargetPIDs.count)),
            .int64(Int64(delta.confirmTargetPIDs.count)),
            .int64(Int64(delta.finalSurvivorPIDs.count)),
            .double(createdAt.timeIntervalSince1970)
        )
    }

    private func insertKillReclaimCalibration(report: KillReport, signatureID: String?, devKind: String?, createdAt: Date) throws {
        try execute(
            """
            INSERT INTO kill_reclaim_calibration(id, operation_id, signature_id, dev_kind, strategy,
                                                 estimated_memory_bytes, realized_memory_bytes,
                                                 calibrated_memory_bytes, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            .text(UUID().uuidString),
            .text(report.operationID.rawValue),
            signatureID.map { .text($0) } ?? .null,
            devKind.map { .text($0) } ?? .null,
            .text(report.strategyUsed.rawValue),
            .int64(Int64(clamping: report.estimatedMemoryReclaimBytes)),
            .int64(Int64(clamping: report.realizedMemoryReclaimBytes)),
            .int64(Int64(clamping: report.calibratedReclaimBytes)),
            .double(createdAt.timeIntervalSince1970)
        )
    }

    private func insertKillExitEvents(report: KillReport) throws {
        for event in report.watcherEvents {
            try execute(
                """
                INSERT INTO kill_exit_events(id, operation_id, pid, kind, message, created_at)
                VALUES(?, ?, ?, ?, ?, ?)
                """,
                .text(event.id),
                .text(event.operationID.rawValue),
                .int64(Int64(event.pid)),
                .text(event.kind.rawValue),
                .text(event.message),
                .double(event.observedAt.timeIntervalSince1970)
            )
        }
    }

    /// Folds the stop into the family's and its kind's posterior for the
    /// strategy that ran.
    private func upsertKillOutcomePosteriors(report: KillReport, signatureID: String?, devKind: String?, createdAt: Date) throws {
        let observation = KillOutcomeObservation(report: report)
        guard observation.outcome != .excluded else { return }
        let rows: [(signatureID: String?, devKind: String?)] = [(signatureID, nil), (nil, devKind)]
        for row in rows where row.signatureID != nil || row.devKind != nil {
            let id = calibrationAggregateID(signatureID: row.signatureID, devKind: row.devKind, strategy: observation.strategy)
            let next = try outcomePosterior(id: id).updating(with: observation, at: createdAt)
            try execute(
                """
                INSERT INTO kill_calibration_aggregates(id, \(RadarStoreQueries.killOutcomePosteriorColumns))
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    operation_count = excluded.operation_count,
                    clean_count = excluded.clean_count,
                    clean_weight = excluded.clean_weight,
                    total_weight = excluded.total_weight,
                    latency_buckets = excluded.latency_buckets,
                    respawn_weight = excluded.respawn_weight,
                    censored_run = excluded.censored_run,
                    updated_at = excluded.updated_at
                """,
                .text(id),
                row.signatureID.map { .text($0) } ?? .null,
                row.devKind.map { .text($0) } ?? .null,
                .text(observation.strategy.rawValue),
                .int64(Int64(next.observationCount)),
                .int64(Int64(next.cleanCount)),
                .double(next.cleanWeight),
                .double(next.totalWeight),
                .text(next.latencyBuckets.map { String($0) }.joined(separator: ",")),
                .double(Double(next.respawnRun)),
                .int64(Int64(next.censoredRun)),
                .double(createdAt.timeIntervalSince1970)
            )
        }
    }

    private func outcomePosterior(id: String) throws -> KillOutcomePosterior {
        let statement = try prepare(RadarStoreQueries.killOutcomePosterior)
        defer { sqlite3_finalize(statement) }
        bind(.text(id), to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return .empty
        }
        return outcomePosterior(from: statement)
    }

    private func outcomePosterior(from statement: OpaquePointer?) -> KillOutcomePosterior {
        KillOutcomePosterior(
            observationCount: Int(sqlite3_column_int64(statement, 3)),
            cleanCount: Int(sqlite3_column_int64(statement, 4)),
            cleanWeight: sqlite3_column_double(statement, 5),
            totalWeight: sqlite3_column_double(statement, 6),
            latencyBuckets: (columnString(statement, 7) ?? "").split(separator: ",").compactMap { Double($0) },
            respawnRun: Int(sqlite3_column_double(statement, 8)),
            censoredRun: Int(sqlite3_column_int64(statement, 9)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        )
    }

    static let killHistoryWindow: TimeInterval = 30 * 24 * 60 * 60

    private func calibrationAggregateID(signatureID: String?, devKind: String?, strategy: KillStrategy) -> String {
        "\(signatureID ?? "*")|\(devKind ?? "*")|\(strategy.rawValue)"
    }

    private func killOperation(from statement: OpaquePointer?) -> KillOperationRecord {
        KillOperationRecord(
            id: KillOperationID(rawValue: columnString(statement, 0) ?? UUID().uuidString),
            signatureID: columnString(statement, 1),
            displayName: columnString(statement, 2) ?? "Process",
            rootPID: Int32(sqlite3_column_int(statement, 3)),
            summary: columnString(statement, 4) ?? "",
            estimatedMemoryReclaimBytes: UInt64(max(0, sqlite3_column_int64(statement, 5))),
            realizedMemoryReclaimBytes: UInt64(max(0, sqlite3_column_int64(statement, 6))),
            gracefulCount: Int(sqlite3_column_int64(statement, 7)),
            forcedCount: Int(sqlite3_column_int64(statement, 8)),
            survivorCount: Int(sqlite3_column_int64(statement, 9)),
            lockedCount: Int(sqlite3_column_int64(statement, 10)),
            staleCount: Int(sqlite3_column_int64(statement, 11)),
            recycledCount: Int(sqlite3_column_int64(statement, 12)),
            durationMilliseconds: sqlite3_column_double(statement, 13),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14))
        )
    }

    private func killEvent(from statement: OpaquePointer?) -> KillOperationEvent {
        let pid: Int32? = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int32(sqlite3_column_int(statement, 3))
        let signalName = columnString(statement, 4)
        let state = columnString(statement, 5).flatMap(KillTargetState.init(rawValue:))
        return KillOperationEvent(
            id: UUID(uuidString: columnString(statement, 0) ?? "") ?? UUID(),
            operationID: KillOperationID(rawValue: columnString(statement, 1) ?? UUID().uuidString),
            kind: KillOperationEventKind(rawValue: columnString(statement, 2) ?? "") ?? .targetUpdated,
            pid: pid,
            signalName: signalName,
            targetState: state,
            message: columnString(statement, 6) ?? "",
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
    }
}
