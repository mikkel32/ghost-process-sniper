import Foundation

public struct SamplerDeadline: Equatable, Sendable {
    public let startedAt: Date
    public let budgetMilliseconds: Double

    public init(startedAt: Date, budgetMilliseconds: Double) {
        self.startedAt = startedAt
        self.budgetMilliseconds = budgetMilliseconds
    }

    public func elapsedMilliseconds(now: Date = Date()) -> Double {
        now.timeIntervalSince(startedAt) * 1_000
    }

    public func isExpired(now: Date = Date()) -> Bool {
        elapsedMilliseconds(now: now) >= budgetMilliseconds
    }
}
