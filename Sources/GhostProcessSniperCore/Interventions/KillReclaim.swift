import Foundation

public struct KillReclaimEstimate: Codable, Equatable, Sendable {
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public let confidence: Double
    public let sourceText: String

    public static let empty = KillReclaimEstimate(
        memoryBytes: 0,
        cpuPercent: 0,
        confidence: 0,
        sourceText: "No reclaim estimate"
    )

    public init(memoryBytes: UInt64, cpuPercent: Double, confidence: Double, sourceText: String) {
        self.memoryBytes = memoryBytes
        self.cpuPercent = max(0, cpuPercent)
        self.confidence = min(1, max(0, confidence))
        self.sourceText = sourceText
    }
}

public struct KillReclaimEstimator: Sendable {
    public init() {}

    public func estimate(plan: KillPlan, targets: [KillTarget]) -> KillReclaimEstimate {
        let targetMemory = targets.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let targetCPU = targets.reduce(0) { $0 + $1.cpuPercent }
        if targetMemory > 0 || targetCPU > 0 {
            return KillReclaimEstimate(
                memoryBytes: targetMemory,
                cpuPercent: targetCPU,
                confidence: 0.82,
                sourceText: "Current owned target footprint"
            )
        }
        if !targets.isEmpty, plan.scope == .ownedFamily, plan.approvedIdentities == nil, let metadata = plan.familyMetadata {
            return KillReclaimEstimate(
                memoryBytes: metadata.memoryBytes,
                cpuPercent: metadata.cpuPercent,
                confidence: 0.58,
                sourceText: "Last radar family totals"
            )
        }
        return .empty
    }

    public func realizedEstimate(from estimate: KillReclaimEstimate, targets: [KillTarget]) -> UInt64 {
        let terminalMemory = targets.reduce(UInt64(0)) { partial, target in
            switch target.state {
            case .terminated, .forceKilled, .exitedBeforeSignal:
                partial + target.memoryBytes
            default:
                partial
            }
        }
        if terminalMemory > 0 {
            return min(estimate.memoryBytes, terminalMemory)
        }
        return targets.contains { $0.state == .survived } ? 0 : estimate.memoryBytes
    }
}
