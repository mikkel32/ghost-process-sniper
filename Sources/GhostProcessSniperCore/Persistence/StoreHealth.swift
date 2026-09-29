import Foundation

public struct StoreHealth: Equatable, Sendable {
    public let backlogCount: Int
    public let pendingActionCount: Int
    public let lastFlushDate: Date?
    public let lastPruneDate: Date?
    public let lastFlushMilliseconds: Double
    public let lastContextMilliseconds: Double
    public let skippedSettingsWriteCount: Int
    public let writeStats: StoreWriteStats
    public let rulesCacheHitCount: Int
    public let errorMessage: String?
    public let lastKillOperationSummary: String?
    /// The store found a corrupt file at open, moved it aside and started fresh.
    public let recoveredFromCorruption: Bool
    /// Models dropped from a backlog that failed to flush.
    public let droppedModelCount: Int

    public static let empty = StoreHealth(
        backlogCount: 0,
        pendingActionCount: 0,
        lastFlushDate: nil,
        lastPruneDate: nil,
        lastFlushMilliseconds: 0,
        lastContextMilliseconds: 0,
        skippedSettingsWriteCount: 0,
        writeStats: .empty,
        rulesCacheHitCount: 0,
        errorMessage: nil,
        lastKillOperationSummary: nil
    )

    public init(
        backlogCount: Int,
        pendingActionCount: Int,
        lastFlushDate: Date?,
        lastPruneDate: Date?,
        lastFlushMilliseconds: Double = 0,
        lastContextMilliseconds: Double = 0,
        skippedSettingsWriteCount: Int = 0,
        writeStats: StoreWriteStats = .empty,
        rulesCacheHitCount: Int = 0,
        errorMessage: String?,
        lastKillOperationSummary: String? = nil,
        recoveredFromCorruption: Bool = false,
        droppedModelCount: Int = 0
    ) {
        self.backlogCount = backlogCount
        self.pendingActionCount = pendingActionCount
        self.lastFlushDate = lastFlushDate
        self.lastPruneDate = lastPruneDate
        self.lastFlushMilliseconds = lastFlushMilliseconds
        self.lastContextMilliseconds = lastContextMilliseconds
        self.skippedSettingsWriteCount = skippedSettingsWriteCount
        self.writeStats = writeStats
        self.rulesCacheHitCount = rulesCacheHitCount
        self.errorMessage = errorMessage
        self.lastKillOperationSummary = lastKillOperationSummary
        self.recoveredFromCorruption = recoveredFromCorruption
        self.droppedModelCount = droppedModelCount
    }
}

/// How much the write-behind store avoided writing.
public struct StoreWriteStats: Equatable, Sendable {
    /// Baseline rows written this session.
    public let baselineWrites: Int
    /// Baselines learned in memory and waiting for their next write.
    public let baselinesDeferred: Int
    /// Flushes that had nothing due and skipped the transaction entirely.
    public let transactionsSkipped: Int
    /// Incident rows written this session. It moves only when the incident
    /// table did, so a reader of it can skip the flushes that changed nothing there.
    public let incidentWrites: Int

    public static let empty = StoreWriteStats(baselineWrites: 0, baselinesDeferred: 0, transactionsSkipped: 0)

    public init(baselineWrites: Int, baselinesDeferred: Int, transactionsSkipped: Int, incidentWrites: Int = 0) {
        self.baselineWrites = baselineWrites
        self.baselinesDeferred = baselinesDeferred
        self.transactionsSkipped = transactionsSkipped
        self.incidentWrites = incidentWrites
    }
}
