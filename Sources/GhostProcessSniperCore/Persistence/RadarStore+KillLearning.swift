import Foundation
import SQLite3

/// Kill operations and the outcome history that tunes future stops.
extension RadarStore {
    public func recordKillOperation(report: KillReport, family: ProcessFamily?, at date: Date = Date()) throws {
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
            try insertKillOutcomeHistory(report: report, signatureID: record.signatureID, createdAt: date)
            try insertKillStrategyHistory(
                report: report,
                signatureID: record.signatureID,
                devKind: family?.classification?.kind.rawValue,
                createdAt: date
            )
            try insertKillSignalOutcomes(report: report, createdAt: date)
            try insertKillGraphDeltas(report: report, createdAt: date)
            try insertKillReclaimCalibration(
                report: report,
                signatureID: record.signatureID,
                devKind: family?.classification?.kind.rawValue,
                createdAt: date
            )
            try insertKillExitEvents(report: report)
            try upsertKillCalibrationAggregate(
                report: report,
                signatureID: record.signatureID,
                devKind: family?.classification?.kind.rawValue,
                createdAt: date
            )
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

    public func killHistorySummary(signatureID: String) throws -> KillHistorySummary {
        let statement = try prepare(RadarStoreQueries.killHistorySummary)
        defer { sqlite3_finalize(statement) }
        bind(.text(signatureID), to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return .empty
        }
        let count = Int(sqlite3_column_int64(statement, 0))
        guard count > 0 else {
            return KillHistorySummary.empty
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

    public func killStrategyHistory(signatureID: String, devKind: String?) throws -> KillHistorySummary {
        guard let devKind, !devKind.isEmpty else {
            return try killHistorySummary(signatureID: signatureID)
        }
        let statement = try prepare(RadarStoreQueries.killStrategyHistoryBySignatureAndKind)
        defer { sqlite3_finalize(statement) }
        bind(.text(signatureID), to: statement, index: 1)
        bind(.text(devKind), to: statement, index: 2)
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

    public func killCalibrationSnapshot(
        signatureID: String,
        devKind: String?,
        strategy: KillStrategy
    ) throws -> KillCalibrationSnapshot {
        let statement = try prepare(RadarStoreQueries.killCalibration)
        defer { sqlite3_finalize(statement) }
        bind(
            .text(calibrationAggregateID(signatureID: signatureID, devKind: devKind, strategy: strategy)),
            to: statement,
            index: 1
        )
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return .empty
        }
        return KillCalibrationSnapshot(
            signatureID: columnString(statement, 0),
            devKind: columnString(statement, 1),
            strategy: columnString(statement, 2).flatMap(KillStrategy.init(rawValue:)),
            operationCount: Int(sqlite3_column_int64(statement, 3)),
            gracefulSuccessRate: sqlite3_column_double(statement, 4),
            forceRate: sqlite3_column_double(statement, 5),
            survivorRate: sqlite3_column_double(statement, 6),
            averageGraceSeconds: sqlite3_column_double(statement, 7),
            reclaimAccuracy: sqlite3_column_double(statement, 8),
            denialPenalty: sqlite3_column_double(statement, 9),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        )
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
                                             realized_memory_bytes, denial_count, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            .int64(Int64(report.deniedPIDs.count + report.failures.count)),
            .double(createdAt.timeIntervalSince1970)
        )
    }

    private func insertKillStrategyHistory(report: KillReport, signatureID: String?, devKind: String?, createdAt: Date) throws {
        try execute(
            """
            INSERT INTO kill_strategy_history(id, operation_id, signature_id, dev_kind, strategy, scope,
                                              graceful_count, forced_count, survivor_count, locked_count,
                                              realized_memory_bytes, denial_count, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            .int64(Int64(report.deniedPIDs.count + report.failures.count)),
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
        let deltas = report.graphSliceDeltas.isEmpty ? [report.finalGraphDelta] : report.graphSliceDeltas
        for delta in deltas where !delta.summary.isEmpty {
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

    private func upsertKillCalibrationAggregate(
        report: KillReport,
        signatureID: String?,
        devKind: String?,
        createdAt: Date
    ) throws {
        guard signatureID != nil || devKind != nil else {
            return
        }
        let id = calibrationAggregateID(
            signatureID: signatureID,
            devKind: devKind,
            strategy: report.strategyUsed
        )
        let existing = try calibrationAggregate(id: id)
        let gracefulSuccess = report.survivorPIDs.isEmpty && report.forcedPIDs.isEmpty && report.failures.isEmpty ? 1.0 : 0.0
        let forceRate = report.forcedPIDs.isEmpty ? 0.0 : 1.0
        let survivorRate = report.survivorPIDs.isEmpty ? 0.0 : 1.0
        let graceSeconds = max(0, report.timeline.signalMilliseconds / 1_000)
        let reclaimAccuracy: Double
        if report.estimatedMemoryReclaimBytes > 0 {
            reclaimAccuracy = min(1.5, Double(report.realizedMemoryReclaimBytes) / Double(report.estimatedMemoryReclaimBytes))
        } else {
            reclaimAccuracy = 1
        }
        let denominator = max(1, report.targetResults.count + report.deniedPIDs.count + report.failures.count)
        let denialPenalty = min(1, Double(report.deniedPIDs.count + report.failures.count) / Double(denominator))

        let next: KillCalibrationSnapshot
        if let existing {
            let alpha = existing.operationCount < 8 ? 1 / Double(existing.operationCount + 1) : 0.18
            next = KillCalibrationSnapshot(
                signatureID: signatureID,
                devKind: devKind,
                strategy: report.strategyUsed,
                operationCount: existing.operationCount + 1,
                gracefulSuccessRate: blend(existing.gracefulSuccessRate, gracefulSuccess, alpha: alpha),
                forceRate: blend(existing.forceRate, forceRate, alpha: alpha),
                survivorRate: blend(existing.survivorRate, survivorRate, alpha: alpha),
                averageGraceSeconds: blend(existing.averageGraceSeconds, graceSeconds, alpha: alpha),
                reclaimAccuracy: blend(existing.reclaimAccuracy, reclaimAccuracy, alpha: alpha),
                denialPenalty: blend(existing.denialPenalty, denialPenalty, alpha: alpha),
                updatedAt: createdAt
            )
        } else {
            next = KillCalibrationSnapshot(
                signatureID: signatureID,
                devKind: devKind,
                strategy: report.strategyUsed,
                operationCount: 1,
                gracefulSuccessRate: gracefulSuccess,
                forceRate: forceRate,
                survivorRate: survivorRate,
                averageGraceSeconds: graceSeconds,
                reclaimAccuracy: reclaimAccuracy,
                denialPenalty: denialPenalty,
                updatedAt: createdAt
            )
        }

        try execute(
            """
            INSERT INTO kill_calibration_aggregates(id, signature_id, dev_kind, strategy,
                                                    operation_count, graceful_success_rate,
                                                    force_rate, survivor_rate, average_grace_seconds,
                                                    reclaim_accuracy, denial_penalty, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                operation_count = excluded.operation_count,
                graceful_success_rate = excluded.graceful_success_rate,
                force_rate = excluded.force_rate,
                survivor_rate = excluded.survivor_rate,
                average_grace_seconds = excluded.average_grace_seconds,
                reclaim_accuracy = excluded.reclaim_accuracy,
                denial_penalty = excluded.denial_penalty,
                updated_at = excluded.updated_at
            """,
            .text(id),
            signatureID.map { .text($0) } ?? .null,
            devKind.map { .text($0) } ?? .null,
            .text(report.strategyUsed.rawValue),
            .int64(Int64(next.operationCount)),
            .double(next.gracefulSuccessRate),
            .double(next.forceRate),
            .double(next.survivorRate),
            .double(next.averageGraceSeconds),
            .double(next.reclaimAccuracy),
            .double(next.denialPenalty),
            .double(createdAt.timeIntervalSince1970)
        )
    }

    private func calibrationAggregate(id: String) throws -> KillCalibrationSnapshot? {
        let statement = try prepare(RadarStoreQueries.killCalibration)
        defer { sqlite3_finalize(statement) }
        bind(.text(id), to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return KillCalibrationSnapshot(
            signatureID: columnString(statement, 0),
            devKind: columnString(statement, 1),
            strategy: columnString(statement, 2).flatMap(KillStrategy.init(rawValue:)),
            operationCount: Int(sqlite3_column_int64(statement, 3)),
            gracefulSuccessRate: sqlite3_column_double(statement, 4),
            forceRate: sqlite3_column_double(statement, 5),
            survivorRate: sqlite3_column_double(statement, 6),
            averageGraceSeconds: sqlite3_column_double(statement, 7),
            reclaimAccuracy: sqlite3_column_double(statement, 8),
            denialPenalty: sqlite3_column_double(statement, 9),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        )
    }

    private func calibrationAggregateID(signatureID: String?, devKind: String?, strategy: KillStrategy) -> String {
        "\(signatureID ?? "*")|\(devKind ?? "*")|\(strategy.rawValue)"
    }

    private func blend(_ old: Double, _ new: Double, alpha: Double) -> Double {
        old * (1 - alpha) + new * alpha
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
