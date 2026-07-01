import Foundation

public struct KillGraphArenaStats: Codable, Equatable, Sendable {
    public let processCount: Int
    public let pidReadCount: Int
    public let arenaBuildMilliseconds: Double
    public let adjacencyBuildMilliseconds: Double
    public let identityIndexCount: Int
    public let processGroupBucketCount: Int
    public let arenaReuseCount: Int
    public let patchedHeavyMetricCount: Int
    public let sliceCacheHitCount: Int
    public let presortedNeighborBucketCount: Int

    public static let empty = KillGraphArenaStats(
        processCount: 0,
        pidReadCount: 0,
        arenaBuildMilliseconds: 0,
        adjacencyBuildMilliseconds: 0,
        identityIndexCount: 0,
        processGroupBucketCount: 0,
        arenaReuseCount: 0,
        patchedHeavyMetricCount: 0,
        sliceCacheHitCount: 0,
        presortedNeighborBucketCount: 0
    )

    public init(
        processCount: Int,
        pidReadCount: Int,
        arenaBuildMilliseconds: Double,
        adjacencyBuildMilliseconds: Double,
        identityIndexCount: Int,
        processGroupBucketCount: Int,
        arenaReuseCount: Int = 0,
        patchedHeavyMetricCount: Int = 0,
        sliceCacheHitCount: Int = 0,
        presortedNeighborBucketCount: Int = 0
    ) {
        self.processCount = processCount
        self.pidReadCount = pidReadCount
        self.arenaBuildMilliseconds = arenaBuildMilliseconds
        self.adjacencyBuildMilliseconds = adjacencyBuildMilliseconds
        self.identityIndexCount = identityIndexCount
        self.processGroupBucketCount = processGroupBucketCount
        self.arenaReuseCount = arenaReuseCount
        self.patchedHeavyMetricCount = patchedHeavyMetricCount
        self.sliceCacheHitCount = sliceCacheHitCount
        self.presortedNeighborBucketCount = presortedNeighborBucketCount
    }

    public func recordingArenaReuse(patchedHeavyMetricCount: Int) -> KillGraphArenaStats {
        KillGraphArenaStats(
            processCount: processCount,
            pidReadCount: pidReadCount,
            arenaBuildMilliseconds: arenaBuildMilliseconds,
            adjacencyBuildMilliseconds: adjacencyBuildMilliseconds,
            identityIndexCount: identityIndexCount,
            processGroupBucketCount: processGroupBucketCount,
            arenaReuseCount: arenaReuseCount + 1,
            patchedHeavyMetricCount: self.patchedHeavyMetricCount + max(0, patchedHeavyMetricCount),
            sliceCacheHitCount: sliceCacheHitCount,
            presortedNeighborBucketCount: presortedNeighborBucketCount
        )
    }

    public func recordingSliceCacheHit() -> KillGraphArenaStats {
        KillGraphArenaStats(
            processCount: processCount,
            pidReadCount: pidReadCount,
            arenaBuildMilliseconds: arenaBuildMilliseconds,
            adjacencyBuildMilliseconds: adjacencyBuildMilliseconds,
            identityIndexCount: identityIndexCount,
            processGroupBucketCount: processGroupBucketCount,
            arenaReuseCount: arenaReuseCount,
            patchedHeavyMetricCount: patchedHeavyMetricCount,
            sliceCacheHitCount: sliceCacheHitCount + 1,
            presortedNeighborBucketCount: presortedNeighborBucketCount
        )
    }
}

public struct KillGraphSliceMember: Identifiable, Equatable, Sendable {
    public var id: ProcessIdentity { process.identity }

    public let process: KillProcessLite
    public let depth: Int

    public init(process: KillProcessLite, depth: Int) {
        self.process = process
        self.depth = depth
    }
}

public struct KillGraphSlice: Equatable, Sendable {
    public let rootIdentity: ProcessIdentity
    public let scope: KillScope
    public let targetMembers: [KillGraphSliceMember]
    public let lockedMembers: [KillGraphSliceMember]
    public let nearbyCandidates: [KillCollateralCandidate]
    public let treeIdentities: Set<ProcessIdentity>
    public let arenaStats: KillGraphArenaStats

    public static func empty(rootIdentity: ProcessIdentity, scope: KillScope) -> KillGraphSlice {
        KillGraphSlice(
            rootIdentity: rootIdentity,
            scope: scope,
            targetMembers: [],
            lockedMembers: [],
            nearbyCandidates: [],
            treeIdentities: [],
            arenaStats: .empty
        )
    }

    public init(
        rootIdentity: ProcessIdentity,
        scope: KillScope,
        targetMembers: [KillGraphSliceMember],
        lockedMembers: [KillGraphSliceMember],
        nearbyCandidates: [KillCollateralCandidate],
        treeIdentities: Set<ProcessIdentity>,
        arenaStats: KillGraphArenaStats
    ) {
        self.rootIdentity = rootIdentity
        self.scope = scope
        self.targetMembers = targetMembers
        self.lockedMembers = lockedMembers
        self.nearbyCandidates = nearbyCandidates
        self.treeIdentities = treeIdentities
        self.arenaStats = arenaStats
    }

    public var summary: String {
        "\(targetMembers.count) target\(targetMembers.count == 1 ? "" : "s"), \(lockedMembers.count) locked, \(nearbyCandidates.count) nearby."
    }

    public func withArenaStats(_ stats: KillGraphArenaStats) -> KillGraphSlice {
        KillGraphSlice(
            rootIdentity: rootIdentity,
            scope: scope,
            targetMembers: targetMembers,
            lockedMembers: lockedMembers,
            nearbyCandidates: nearbyCandidates,
            treeIdentities: treeIdentities,
            arenaStats: stats
        )
    }
}

public struct KillGraphArena: Equatable, Sendable {
    public let processes: [KillProcessLite]
    public let sampledAt: Date
    public let stats: KillGraphArenaStats

    private let indexByIdentity: [ProcessIdentity: Int]
    private let indicesByPID: [Int32: [Int]]
    private let childrenByPID: [Int32: [Int]]
    private let processGroupBuckets: [Int32: [Int]]

    public static let empty = KillGraphArena(processes: [], sampledAt: Date(timeIntervalSince1970: 0))

    public init(
        processes: [KillProcessLite],
        sampledAt: Date,
        pidReadCount: Int? = nil
    ) {
        let started = Date()
        var identityIndex: [ProcessIdentity: Int] = [:]
        var pidIndex: [Int32: [Int]] = [:]
        var groupBuckets: [Int32: [Int]] = [:]
        identityIndex.reserveCapacity(processes.count)
        pidIndex.reserveCapacity(processes.count)

        for index in processes.indices {
            let process = processes[index]
            identityIndex[process.identity] = index
            pidIndex[process.pid, default: []].append(index)
            if process.processGroupID > 0 {
                groupBuckets[process.processGroupID, default: []].append(index)
            }
        }
        for groupID in groupBuckets.keys {
            groupBuckets[groupID]?.sort {
                if processes[$0].pid != processes[$1].pid {
                    return processes[$0].pid < processes[$1].pid
                }
                return processes[$0].name < processes[$1].name
            }
        }

        let adjacencyStart = Date()
        var childIndex: [Int32: [Int]] = [:]
        childIndex.reserveCapacity(processes.count)
        for index in processes.indices {
            childIndex[processes[index].parentPID, default: []].append(index)
        }
        let adjacencyMilliseconds = Date().timeIntervalSince(adjacencyStart) * 1_000
        let buildMilliseconds = Date().timeIntervalSince(started) * 1_000

        self.processes = processes
        self.sampledAt = sampledAt
        self.indexByIdentity = identityIndex
        self.indicesByPID = pidIndex
        self.childrenByPID = childIndex
        self.processGroupBuckets = groupBuckets
        self.stats = KillGraphArenaStats(
            processCount: processes.count,
            pidReadCount: pidReadCount ?? processes.count,
            arenaBuildMilliseconds: buildMilliseconds,
            adjacencyBuildMilliseconds: adjacencyMilliseconds,
            identityIndexCount: identityIndex.count,
            processGroupBucketCount: groupBuckets.count,
            presortedNeighborBucketCount: groupBuckets.count
        )
    }

    private init(
        processes: [KillProcessLite],
        sampledAt: Date,
        stats: KillGraphArenaStats,
        indexByIdentity: [ProcessIdentity: Int],
        indicesByPID: [Int32: [Int]],
        childrenByPID: [Int32: [Int]],
        processGroupBuckets: [Int32: [Int]]
    ) {
        self.processes = processes
        self.sampledAt = sampledAt
        self.stats = stats
        self.indexByIdentity = indexByIdentity
        self.indicesByPID = indicesByPID
        self.childrenByPID = childrenByPID
        self.processGroupBuckets = processGroupBuckets
    }

    public func replacingProcesses(
        _ updatedProcesses: [KillProcessLite],
        patchedHeavyMetricCount: Int
    ) -> KillGraphArena {
        guard updatedProcesses.count == processes.count else {
            return KillGraphArena(
                processes: updatedProcesses,
                sampledAt: sampledAt,
                pidReadCount: stats.pidReadCount
            )
        }
        return KillGraphArena(
            processes: updatedProcesses,
            sampledAt: sampledAt,
            stats: stats.recordingArenaReuse(patchedHeavyMetricCount: patchedHeavyMetricCount),
            indexByIdentity: indexByIdentity,
            indicesByPID: indicesByPID,
            childrenByPID: childrenByPID,
            processGroupBuckets: processGroupBuckets
        )
    }

    public func process(for identity: ProcessIdentity) -> KillProcessLite? {
        guard let index = indexByIdentity[identity] else {
            return nil
        }
        return processes[index]
    }

    public func processes(for pid: Int32) -> [KillProcessLite] {
        indicesByPID[pid, default: []].map { processes[$0] }
    }

    public func hasRecycledPID(for identity: ProcessIdentity) -> Bool {
        processes(for: identity.pid).contains { $0.identity != identity }
    }

    public func descendants(of rootIdentity: ProcessIdentity) -> [KillGraphSliceMember] {
        guard let rootIndex = indexByIdentity[rootIdentity] else {
            return []
        }

        var output: [KillGraphSliceMember] = []
        var stack: [(Int, Int)] = [(rootIndex, 0)]
        var seen = Set<Int>()
        output.reserveCapacity(8)

        while let item = stack.popLast() {
            guard seen.insert(item.0).inserted else {
                continue
            }
            let process = processes[item.0]
            output.append(KillGraphSliceMember(process: process, depth: item.1))
            for childIndex in childrenByPID[process.pid, default: []] {
                stack.append((childIndex, item.1 + 1))
            }
        }
        return output
    }

    public func processGroupNeighbors(
        rootIdentity: ProcessIdentity,
        currentUserID: UInt32,
        excluding identities: Set<ProcessIdentity>,
        limit: Int = 12
    ) -> [KillProcessLite] {
        guard let root = process(for: rootIdentity),
              root.processGroupID > 0 else {
            return []
        }
        return processGroupBuckets[root.processGroupID, default: []]
            .lazy
            .map { processes[$0] }
            .filter { $0.userID == currentUserID && !identities.contains($0.identity) }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func slice(
        plan: KillPlan,
        currentUserID: UInt32,
        nearbyLimit: Int = 12
    ) -> KillGraphSlice {
        let scopedMembers: [KillGraphSliceMember]
        switch plan.scope {
        case .singleRoot:
            scopedMembers = process(for: plan.rootIdentity).map { [KillGraphSliceMember(process: $0, depth: 0)] } ?? []
        case .ownedFamily, .ownedProcessGroupPreview:
            scopedMembers = descendants(of: plan.rootIdentity)
        }

        var targetMembers: [KillGraphSliceMember] = []
        var lockedMembers: [KillGraphSliceMember] = []
        var treeIdentities = Set<ProcessIdentity>()
        targetMembers.reserveCapacity(scopedMembers.count)
        lockedMembers.reserveCapacity(scopedMembers.count / 4)

        for member in scopedMembers {
            treeIdentities.insert(member.process.identity)
            if member.process.userID == currentUserID {
                targetMembers.append(member)
            } else {
                lockedMembers.append(member)
            }
        }

        if plan.scope == .ownedProcessGroupPreview {
            let existing = Set(targetMembers.map(\.process.identity))
            let neighbors = processGroupNeighbors(
                rootIdentity: plan.rootIdentity,
                currentUserID: currentUserID,
                excluding: existing,
                limit: nearbyLimit
            )
            for neighbor in neighbors {
                targetMembers.append(KillGraphSliceMember(process: neighbor, depth: 1))
                treeIdentities.insert(neighbor.identity)
            }
        }

        let excluding = Set(targetMembers.map(\.process.identity))
        let nearby = processGroupNeighbors(
            rootIdentity: plan.rootIdentity,
            currentUserID: currentUserID,
            excluding: excluding,
            limit: nearbyLimit
        ).map {
            KillCollateralCandidate(process: $0, reason: "Same process group, not targeted by \(plan.scope.label.lowercased())")
        }

        return KillGraphSlice(
            rootIdentity: plan.rootIdentity,
            scope: plan.scope,
            targetMembers: targetMembers,
            lockedMembers: lockedMembers,
            nearbyCandidates: nearby,
            treeIdentities: treeIdentities,
            arenaStats: stats
        )
    }

    public func conversionIdentities(
        plan: KillPlan,
        currentUserID: UInt32,
        nearbyLimit: Int = 12
    ) -> Set<ProcessIdentity> {
        var identities = Set(plan.targetIdentities)
        let slice = slice(plan: plan, currentUserID: currentUserID, nearbyLimit: nearbyLimit)
        identities.formUnion(slice.targetMembers.map(\.process.identity))
        identities.formUnion(slice.lockedMembers.map(\.process.identity))
        identities.formUnion(slice.nearbyCandidates.map(\.identity))
        return identities
    }
}

public struct KillArenaBuilder: Sendable {
    public init() {}

    public func build(
        processes: [KillProcessLite],
        sampledAt: Date,
        pidReadCount: Int
    ) -> KillGraphArena {
        KillGraphArena(
            processes: processes,
            sampledAt: sampledAt,
            pidReadCount: pidReadCount
        )
    }

    public func patchHeavyMetrics(
        arena: KillGraphArena,
        updatedProcesses: [KillProcessLite],
        patchedHeavyMetricCount: Int
    ) -> KillGraphArena {
        arena.replacingProcesses(
            updatedProcesses,
            patchedHeavyMetricCount: patchedHeavyMetricCount
        )
    }
}

public struct KillGraphSliceCacheKey: Hashable, Sendable {
    public let rootIdentity: ProcessIdentity
    public let scope: KillScope
    public let sampledAt: Date
    public let processCount: Int

    public init(rootIdentity: ProcessIdentity, scope: KillScope, sampledAt: Date, processCount: Int) {
        self.rootIdentity = rootIdentity
        self.scope = scope
        self.sampledAt = sampledAt
        self.processCount = processCount
    }

    public init(plan: KillPlan, arena: KillGraphArena) {
        self.init(
            rootIdentity: plan.rootIdentity,
            scope: plan.scope,
            sampledAt: arena.sampledAt,
            processCount: arena.processes.count
        )
    }
}

public struct KillGraphSliceCache: Sendable {
    private var slices: [KillGraphSliceCacheKey: KillGraphSlice] = [:]
    public private(set) var hitCount: Int = 0

    public init() {}

    public mutating func slice(
        plan: KillPlan,
        arena: KillGraphArena,
        currentUserID: UInt32,
        nearbyLimit: Int = 12
    ) -> (slice: KillGraphSlice, hit: Bool) {
        let key = KillGraphSliceCacheKey(plan: plan, arena: arena)
        if let cached = slices[key] {
            hitCount += 1
            return (cached.withArenaStats(cached.arenaStats.recordingSliceCacheHit()), true)
        }
        let slice = arena.slice(plan: plan, currentUserID: currentUserID, nearbyLimit: nearbyLimit)
        slices[key] = slice
        if slices.count > 32 {
            slices.remove(at: slices.startIndex)
        }
        return (slice, false)
    }
}

public struct KillGraphDeltaEngine: Sendable {
    public init() {}

    public func diff(
        plan: KillPlan,
        targets: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget],
        locked: [KillTarget],
        treeIdentities: Set<ProcessIdentity>,
        survivorPIDs: [Int32] = []
    ) -> KillTargetDiff {
        let planned = Set(plan.targetIdentities)
        let current = Set(targets.map(\.identity))
        let added = current.subtracting(planned).map(\.pid)
        let reparented = locked
            .filter { target in
                plan.targetIdentities.contains(target.identity) &&
                    !treeIdentities.isEmpty &&
                    !treeIdentities.contains(target.identity)
            }
            .map(\.pid)
        return KillTargetDiff(
            addedPIDs: added,
            exitedPIDs: stale.map(\.pid),
            recycledPIDs: recycled.map(\.pid),
            reparentedPIDs: reparented,
            survivorPIDs: survivorPIDs
        )
    }
}
