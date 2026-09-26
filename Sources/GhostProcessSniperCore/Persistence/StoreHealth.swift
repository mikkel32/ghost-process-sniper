import Foundation

public struct StoreHealth: Equatable, Sendable {
    public let backlogCount: Int
    public let pendingActionCount: Int
    public let lastFlushDate: Date?
    public let lastPruneDate: Date?
    public let lastFlushMilliseconds: Double
    public let lastContextMilliseconds: Double
    public let skippedSettingsWriteCount: Int
    public let coalescingStats: StoreCoalescingStats
    public let rulesCacheHitCount: Int
    public let errorMessage: String?
    public let lastKillOperationSummary: String?

    public static let empty = StoreHealth(
        backlogCount: 0,
        pendingActionCount: 0,
        lastFlushDate: nil,
        lastPruneDate: nil,
        lastFlushMilliseconds: 0,
        lastContextMilliseconds: 0,
        skippedSettingsWriteCount: 0,
        coalescingStats: .empty,
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
        coalescingStats: StoreCoalescingStats = .empty,
        rulesCacheHitCount: Int = 0,
        errorMessage: String?,
        lastKillOperationSummary: String? = nil
    ) {
        self.backlogCount = backlogCount
        self.pendingActionCount = pendingActionCount
        self.lastFlushDate = lastFlushDate
        self.lastPruneDate = lastPruneDate
        self.lastFlushMilliseconds = lastFlushMilliseconds
        self.lastContextMilliseconds = lastContextMilliseconds
        self.skippedSettingsWriteCount = skippedSettingsWriteCount
        self.coalescingStats = coalescingStats
        self.rulesCacheHitCount = rulesCacheHitCount
        self.errorMessage = errorMessage
        self.lastKillOperationSummary = lastKillOperationSummary
    }
}

public struct StoreCoalescingStats: Equatable, Sendable {
    public let forecastCandidates: Int
    public let forecastWrites: Int
    public let recommendationWrites: Int
    public let recommendationSkippedCount: Int

    public static let empty = StoreCoalescingStats(
        forecastCandidates: 0,
        forecastWrites: 0,
        recommendationWrites: 0,
        recommendationSkippedCount: 0
    )

    public init(
        forecastCandidates: Int,
        forecastWrites: Int,
        recommendationWrites: Int,
        recommendationSkippedCount: Int
    ) {
        self.forecastCandidates = forecastCandidates
        self.forecastWrites = forecastWrites
        self.recommendationWrites = recommendationWrites
        self.recommendationSkippedCount = recommendationSkippedCount
    }
}
