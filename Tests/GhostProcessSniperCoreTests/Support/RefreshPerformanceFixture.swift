import Foundation
@testable import GhostProcessSniperCore

enum RefreshPerformanceFixture {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func process(_ index: Int, pid: Int32? = nil, start: UInt64 = 1_999_990_000) -> ProcessMetrics {
        let group = index / 2
        let memory = UInt64(64 + index % 10) * 1_048_576
        return ProcessMetrics(
            identity: ProcessIdentity(pid: pid ?? Int32(40_000 + index),
                startTimeSeconds: start, startTimeMicroseconds: 0),
            parentPID: 1, userID: 501, ownerName: "fixture",
            name: "tool-\(group)", executablePath: "/usr/local/bin/fixture-tool-\(group)",
            commandLine: "tool-\(group) --fixture", residentMemoryBytes: memory,
            physicalFootprintBytes: memory, virtualMemoryBytes: memory * 2,
            cpuPercent: Double(index % 5), totalProcessorSeconds: 10,
            threadCount: 2, isSystemProcess: false, sampledAt: now)
    }

    static func family(_ root: ProcessMetrics, members: [ProcessMetrics]? = nil,
                       level: GhostLevel = .quiet) -> ProcessFamily {
        let members = members ?? [root]
        return ProcessFamily(root: root, members: members,
            totalResidentMemoryBytes: members.reduce(0) { $0 + $1.residentMemoryBytes },
            totalPhysicalFootprintBytes: members.reduce(0) { $0 + $1.memoryForScoringBytes },
            totalCPUPercent: members.reduce(0) { $0 + $1.cpuPercent },
            totalGPUPercent: members.reduce(0) { $0 + $1.gpuUsagePercent },
            devConfidence: 0, commandHints: [], trend: .empty,
            score: GhostScore(value: 0, level: level, reasons: [], components: [],
                heat: GhostHeat(value: 0, level: level, confidence: 0,
                    evidence: [], sustainedSignalCount: 0)),
            ownedIdentities: members.map(\.identity), protectedPIDs: [])
    }

    static func cluster(_ index: Int, members: [ProcessMetrics]) -> DuplicateProcessCluster {
        DuplicateProcessCluster(
            key: DuplicateClusterKey(kind: .executablePath, value: "/benchmark/group-\(index)",
                displayName: "Group \(index)"),
            displayName: "Group \(index)", members: members,
            independentRootCount: members.count, likelyKind: .cliTool,
            classificationReason: "Synthetic duplicate fixture")
    }

    static func population(_ count: Int) -> (families: [ProcessFamily], clusters: [DuplicateProcessCluster]) {
        let processes = (0..<count).map { process($0) }
        let families = processes.map { family($0) }
        let clusters = stride(from: 0, to: count - 1, by: 2).map { index in
            cluster(index / 2, members: [processes[index], processes[index + 1]])
        }
        return (families, clusters)
    }

    /// The pre-refactor algorithm, retained only as an independent test oracle
    /// and paired benchmark. It deliberately reconstructs each cluster too.
    static func legacyResolve(_ clusters: [DuplicateProcessCluster],
                              families: [ProcessFamily]) -> [DuplicateProcessCluster] {
        let familySets = families.map {
            (key: $0.familyKey, identities: Set($0.members.map(\.identity)))
        }
        return clusters.map { cluster in
            let identities = Set(cluster.members.map(\.identity))
            let related = familySets.filter { !identities.isDisjoint(with: $0.identities) }
            return DuplicateProcessCluster(key: cluster.key, displayName: cluster.displayName,
                members: cluster.members, independentRootCount: cluster.independentRootCount,
                likelyKind: cluster.likelyKind, classificationReason: cluster.classificationReason,
                relatedFamilyKeys: related.map(\.key),
                isInternalToSingleFamily: related.contains { identities.isSubset(of: $0.identities) })
        }.sorted { lhs, rhs in
            if lhs.memberCount != rhs.memberCount { return lhs.memberCount > rhs.memberCount }
            if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes {
                return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes
            }
            return lhs.totalCPUPercent > rhs.totalCPUPercent
        }
    }
}
