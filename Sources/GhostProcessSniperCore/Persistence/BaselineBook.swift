import Foundation

/// Learned per-signature baselines. Rows are cached after the first read, and
/// signatures known to have no row are remembered, so a refresh never re-reads
/// what it already knows.
///
/// Learning happens in memory on every model; rows are written behind. A
/// changed baseline is persisted once it has learned `persistEverySamples`
/// more samples or has waited `persistAfter`, in passes at most
/// `persistPassInterval` apart, and shutdown persists the rest. A crash loses
/// at most that much learning, which the next samples make up.
///
/// Learning and persistence state are staged until the caller's transaction
/// commits: a rolled-back flush that is retried must not learn the same
/// samples twice.
final class BaselineBook {
    static let persistEverySamples = 5
    static let persistAfter: TimeInterval = 10 * 60
    static let persistPassInterval: TimeInterval = 60
    private static let maximumUpdates = 512
    // Keeps the cold-load query comfortably below SQLite variable limits.
    private static let chunkSize = 400

    /// A learned change that is not on disk yet.
    struct Dirty: Equatable {
        var persistedSampleCount: Int
        var since: Date
    }

    private let db: SQLiteDatabase
    private var cache: [String: FamilyBaseline] = [:]
    /// Signatures with no row, and when they were last asked for.
    private var knownMissing: [String: Date] = [:]
    private var dirty: [String: Dirty] = [:]
    private var lastPersistPass: Date?
    private var roundRobinOffset = 0

    private var staged: [String: FamilyBaseline] = [:]
    /// A nil value clears the entry on commit.
    private var stagedDirty: [String: Dirty?] = [:]
    private var stagedPersistPass: Date?
    private var stagedRoundRobinOffset: Int?
    private var pendingUpserts: [FamilyBaseline] = []

    private(set) var writeCount = 0

    init(db: SQLiteDatabase) {
        self.db = db
    }

    var hasPendingWrites: Bool {
        !pendingUpserts.isEmpty
    }

    /// Baselines learned but not written yet.
    var deferredCount: Int {
        dirty.count
    }

    func baselines(for signatureIDs: [String], at date: Date? = nil) throws -> [String: FamilyBaseline] {
        guard !signatureIDs.isEmpty else {
            return [:]
        }

        let uniqueIDs = Array(Set(signatureIDs))
        var result: [String: FamilyBaseline] = [:]
        result.reserveCapacity(uniqueIDs.count)
        var missing: [String] = []
        missing.reserveCapacity(uniqueIDs.count)

        for signatureID in uniqueIDs {
            if let pending = staged[signatureID] {
                result[signatureID] = pending
            } else if let cached = cache[signatureID] {
                result[signatureID] = cached
            } else if knownMissing[signatureID] != nil {
                if let date {
                    knownMissing[signatureID] = date
                }
            } else {
                missing.append(signatureID)
            }
        }

        var start = 0
        while start < missing.count {
            let end = min(start + Self.chunkSize, missing.count)
            let chunk = Array(missing[start..<end])
            let slots = SQLiteDatabase.placeholderCount(for: chunk.count)
            var values = chunk.map { SQLiteValue.text($0) }
            values += Array(repeating: .null, count: slots - chunk.count)

            var found = Set<String>()
            try db.query(
                """
                SELECT \(RadarStoreRows.baselineColumns)
                FROM baselines
                WHERE signature_id IN (\(SQLiteDatabase.placeholders(count: slots)))
                """,
                values
            ) { row in
                let baseline = RadarStoreRows.baseline(from: row)
                let signatureID = baseline.signature.id
                cache[signatureID] = baseline
                knownMissing[signatureID] = nil
                result[signatureID] = baseline
                found.insert(signatureID)
            }

            for signatureID in chunk where !found.contains(signatureID) {
                knownMissing[signatureID] = date ?? .distantPast
            }
            start = end
        }
        return result
    }

    /// Learns one model into the staged baselines. Nothing is written.
    func learn(from families: [ProcessFamily], at date: Date,
               leakVelocityLimit: Double = ThresholdSettings.smart.leakVelocityMegabytesPerMinute) throws {
        let candidates = updateCandidates(from: families)
        let existing = try baselines(for: candidates.map(\.signature.id), at: date)
        let learner = FamilyBaselineLearner()
        for family in candidates {
            let signatureID = family.signature.id
            let previous = existing[signatureID]
            let baseline = learner.updated(existing: previous, family: family, now: date, leakVelocityLimit: leakVelocityLimit)
            guard baseline != previous else { continue }
            staged[signatureID] = baseline
            if currentDirty(signatureID) == nil {
                stagedDirty[signatureID] = Dirty(persistedSampleCount: previous?.sampleCount ?? 0, since: date)
            }
        }
    }

    /// Queues the dirty baselines that are due. `force` queues every one,
    /// for shutdown.
    func stagePersist(now: Date, force: Bool) {
        if !force, let last = stagedPersistPass ?? lastPersistPass, now.timeIntervalSince(last) < Self.persistPassInterval {
            return
        }
        var due: [FamilyBaseline] = []
        for signatureID in Set(dirty.keys).union(stagedDirty.keys) {
            guard let state = currentDirty(signatureID),
                  let baseline = staged[signatureID] ?? cache[signatureID] else { continue }
            let learned = baseline.sampleCount - state.persistedSampleCount
            if force || learned >= Self.persistEverySamples || now.timeIntervalSince(state.since) >= Self.persistAfter {
                due.append(baseline)
                stagedDirty[signatureID] = .some(nil)
            }
        }
        stagedPersistPass = now
        pendingUpserts = due.sorted { $0.signature.id < $1.signature.id }
    }

    func writeStaged() throws {
        for baseline in pendingUpserts {
            try upsert(baseline)
        }
    }

    func commitStaged() {
        for (signatureID, baseline) in staged {
            cache[signatureID] = baseline
            knownMissing[signatureID] = nil
        }
        for (signatureID, state) in stagedDirty {
            dirty[signatureID] = state
        }
        if let stagedPersistPass {
            lastPersistPass = stagedPersistPass
        }
        if let stagedRoundRobinOffset {
            roundRobinOffset = stagedRoundRobinOffset
        }
        writeCount += pendingUpserts.count
        discardStaged()
    }

    func discardStaged() {
        staged.removeAll(keepingCapacity: true)
        stagedDirty.removeAll(keepingCapacity: true)
        stagedPersistPass = nil
        stagedRoundRobinOffset = nil
        pendingUpserts.removeAll(keepingCapacity: true)
    }

    /// The file was replaced: every cached baseline is written to the new
    /// one at the next persist pass.
    func markAllUnpersisted() {
        discardStaged()
        for signatureID in cache.keys {
            dirty[signatureID] = Dirty(persistedSampleCount: 0, since: .distantPast)
        }
        lastPersistPass = nil
    }

    /// Forgets clean rows and misses not seen since `cutoff`; a signature that
    /// comes back reloads from disk.
    func evict(notSeenSince cutoff: Date) {
        cache = cache.filter { dirty[$0.key] != nil || $0.value.lastSeenAt >= cutoff }
        knownMissing = knownMissing.filter { $0.value >= cutoff }
    }

    private func currentDirty(_ signatureID: String) -> Dirty? {
        if let staged = stagedDirty[signatureID] {
            return staged
        }
        return dirty[signatureID]
    }

    private func updateCandidates(from families: [ProcessFamily]) -> [ProcessFamily] {
        let maximumUpdates = Self.maximumUpdates
        var seenSignatures = Set<String>()
        let uniqueFamilies = families.filter { family in
            seenSignatures.insert(family.signature.id).inserted
        }
        guard uniqueFamilies.count > maximumUpdates else {
            return uniqueFamilies
        }

        // Always spend part of the budget on families that can affect the
        // current diagnosis. Quiet families still learn through a rotating
        // slice, so a huge process table cannot turn into thousands of
        // updates every flush.
        let priorityLimit = maximumUpdates / 2
        var selected: [ProcessFamily] = []
        selected.reserveCapacity(maximumUpdates)
        var selectedIDs = Set<String>()

        for family in uniqueFamilies where
            family.score.level >= .watch ||
            family.forecastIsCredibleEarlyWarning ||
            family.recentIncidentCount > 0 {
            guard selected.count < priorityLimit else { break }
            selected.append(family)
            selectedIDs.insert(family.signature.id)
        }

        let quiet = uniqueFamilies.filter { !selectedIDs.contains($0.signature.id) }
        guard !quiet.isEmpty, selected.count < maximumUpdates else {
            return selected
        }

        let start = (stagedRoundRobinOffset ?? roundRobinOffset) % quiet.count
        let remaining = maximumUpdates - selected.count
        for offset in 0..<min(remaining, quiet.count) {
            selected.append(quiet[(start + offset) % quiet.count])
        }
        stagedRoundRobinOffset = (start + remaining) % quiet.count
        return selected
    }

    private func upsert(_ baseline: FamilyBaseline) throws {
        try db.execute(
            """
            INSERT INTO baselines(\(RadarStoreRows.baselineColumns))
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(signature_id) DO UPDATE SET
                display_name = excluded.display_name,
                canonical_path = excluded.canonical_path,
                command_fingerprint = excluded.command_fingerprint,
                sample_count = excluded.sample_count,
                mean_memory_bytes = excluded.mean_memory_bytes,
                peak_memory_bytes = excluded.peak_memory_bytes,
                mean_cpu_percent = excluded.mean_cpu_percent,
                peak_cpu_percent = excluded.peak_cpu_percent,
                mean_leak_velocity = excluded.mean_leak_velocity,
                incident_count = excluded.incident_count,
                last_seen_at = excluded.last_seen_at,
                first_seen_at = excluded.first_seen_at,
                measurement_version = excluded.measurement_version,
                memory_variance = excluded.memory_variance,
                cpu_variance = excluded.cpu_variance,
                observed_seconds = excluded.observed_seconds,
                session_count = excluded.session_count
            """,
            .text(baseline.signature.id),
            .text(baseline.signature.displayName),
            .text(baseline.signature.canonicalPath),
            .text(baseline.signature.commandFingerprint),
            .int64(Int64(baseline.sampleCount)),
            .double(baseline.meanMemoryBytes),
            .int64(Int64(clamping: baseline.peakMemoryBytes)),
            .double(baseline.meanCPUPercent),
            .double(baseline.peakCPUPercent),
            .double(baseline.meanLeakVelocityMegabytesPerMinute),
            .int64(Int64(baseline.incidentCount)),
            .double(baseline.firstSeenAt.timeIntervalSince1970),
            .double(baseline.lastSeenAt.timeIntervalSince1970),
            .int64(Int64(baseline.measurementVersion ?? 0)),
            .double(baseline.memoryVariance),
            .double(baseline.cpuVariance),
            .double(baseline.observedSeconds),
            .int64(Int64(baseline.sessionCount))
        )
    }
}
