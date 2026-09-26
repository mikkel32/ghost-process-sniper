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

    /// Memory from the fresh targets. A kill snapshot cannot measure CPU,
    /// so a target without it takes the radar's last reading for that
    /// exact process; a reused PID is someone else.
    public func estimate(plan: KillPlan, targets: [KillTarget]) -> KillReclaimEstimate {
        let radar = Self.radarCPU(plan)
        let targetMemory = targets.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        var usedRadar = false
        let targetCPU = targets.reduce(0.0) { total, target in
            guard target.cpuPercent <= 0, let reading = radar[target.identity], reading > 0 else { return total + target.cpuPercent }
            usedRadar = true
            return total + reading
        }
        if targetMemory > 0 || targetCPU > 0 {
            return KillReclaimEstimate(
                memoryBytes: targetMemory,
                cpuPercent: targetCPU,
                confidence: 0.82,
                sourceText: usedRadar ? "Memory now, CPU from the last scan" : "Current owned target footprint"
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

    /// The radar's CPU per exact process.
    static func radarCPU(_ plan: KillPlan) -> [ProcessIdentity: Double] {
        Dictionary((plan.workload?.processes ?? []).compactMap { process in process.identity.map { ($0, process.cpuPercent) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Memory of the targets that are gone, less what a supervisor took
    /// straight back: each restarted name cancels one stopped process of it.
    public func realizedEstimate(from estimate: KillReclaimEstimate, targets: [KillTarget], respawnedNames: [String] = []) -> UInt64 {
        var gone = targets.filter { [.terminated, .forceKilled, .exitedBeforeSignal].contains($0.state) }
        for name in respawnedNames {
            if let index = gone.firstIndex(where: { $0.name == name }) { gone.remove(at: index) }
        }
        let terminalMemory = gone.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        if terminalMemory > 0 {
            return min(estimate.memoryBytes, terminalMemory)
        }
        if !respawnedNames.isEmpty { return 0 }
        return targets.contains { $0.state == .survived } ? 0 : estimate.memoryBytes
    }
}
