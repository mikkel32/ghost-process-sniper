import Darwin
import Foundation

public struct DuplicateClusterKey: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case executablePath
        case commandPrefix
    }

    public let kind: Kind
    public let value: String
    public let displayName: String

    public var id: String { "\(kind.rawValue)|\(value)" }

    public init(kind: Kind, value: String, displayName: String) {
        self.kind = kind
        self.value = value
        self.displayName = displayName
    }
}

public struct DuplicateProcessCluster: Identifiable, Equatable, Sendable {
    public var id: String { key.id }

    public let key: DuplicateClusterKey
    public let displayName: String
    public let members: [ProcessMetrics]
    public let memberCount: Int
    public let independentRootCount: Int
    public let totalResidentMemoryBytes: UInt64
    public let totalPhysicalFootprintBytes: UInt64
    public let totalCPUPercent: Double
    public let ownerName: String
    public let sampleFreshness: Date?
    public let likelyKind: DevProcessKind
    public let classificationReason: String
    public let commandHints: [String]
    public let pathHints: [String]
    public let representativePIDs: [Int32]
    public private(set) var relatedFamilyKeys: [String]
    public private(set) var isInternalToSingleFamily: Bool
    /// The topmost member of each independent copy.
    public let copyRootIdentities: [ProcessIdentity]
    /// The copy to keep running: the one in a terminal, else the most
    /// recently active, else the newest.
    public let keepIdentity: ProcessIdentity?
    /// Why that copy is kept, e.g. "the newest copy".
    public let keepReason: String
    /// Listening ports of the redundant copies, when forensics knows them.
    public let redundantPorts: [Int]

    /// The copies worth stopping; stop the family that owns each one.
    public let redundantRootIdentities: [ProcessIdentity]
    /// Changes whenever the keep, the redundant copies or their ports do.
    let copyPlanHash: Int

    /// Two or more copies started independently, not one tool's worker pool.
    public var countsAsIndependentCopies: Bool {
        independentRootCount >= 2 && !isInternalToSingleFamily
    }

    public init(
        key: DuplicateClusterKey,
        displayName: String,
        members: [ProcessMetrics],
        independentRootCount: Int,
        likelyKind: DevProcessKind,
        classificationReason: String,
        relatedFamilyKeys: [String] = [],
        isInternalToSingleFamily: Bool = false,
        copyRootIdentities: [ProcessIdentity] = [],
        keepIdentity: ProcessIdentity? = nil,
        keepReason: String = "the newest copy"
    ) {
        let sorted = members.sorted { lhs, rhs in
            if lhs.memoryForScoringBytes != rhs.memoryForScoringBytes {
                return lhs.memoryForScoringBytes > rhs.memoryForScoringBytes
            }
            return lhs.pid < rhs.pid
        }
        self.key = key
        self.displayName = displayName
        self.members = sorted
        self.memberCount = sorted.count
        self.independentRootCount = independentRootCount
        self.totalResidentMemoryBytes = sorted.reduce(UInt64(0)) { $0 + $1.residentMemoryBytes }
        self.totalPhysicalFootprintBytes = sorted.reduce(UInt64(0)) { $0 + $1.memoryForScoringBytes }
        self.totalCPUPercent = sorted.reduce(0) { $0 + $1.cpuPercent }
        self.ownerName = sorted.first?.ownerName ?? "unknown"
        self.sampleFreshness = sorted.map(\.sampledAt).max()
        self.likelyKind = likelyKind
        self.classificationReason = classificationReason
        self.commandHints = Self.uniqueHints(sorted.map(\.commandLine), limit: 4)
        self.pathHints = Self.uniqueHints(sorted.map(\.executablePath).filter { !$0.isEmpty }, limit: 4)
        self.representativePIDs = sorted.prefix(8).map(\.pid)
        self.relatedFamilyKeys = relatedFamilyKeys.sorted()
        self.isInternalToSingleFamily = isInternalToSingleFamily
        self.copyRootIdentities = copyRootIdentities
        self.keepIdentity = keepIdentity
        self.keepReason = keepReason
        let redundant = keepIdentity == nil ? [] : copyRootIdentities.filter { $0 != keepIdentity }
        self.redundantRootIdentities = redundant
        self.redundantPorts = Self.ports(of: redundant, in: sorted)
        var hasher = Hasher()
        hasher.combine(keepIdentity)
        hasher.combine(redundant)
        hasher.combine(redundantPorts)
        self.copyPlanHash = hasher.finalize()
    }

    private static func ports(of copies: [ProcessIdentity], in members: [ProcessMetrics]) -> [Int] {
        guard !copies.isEmpty else { return [] }
        let wanted = Set(copies)
        let memberPIDs = Set(members.map(\.pid))
        let byPID = Dictionary(members.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // A copy's matching descendants serve its ports too.
        func copyRoot(of member: ProcessMetrics) -> ProcessIdentity {
            var current = member
            var steps = 0
            while memberPIDs.contains(current.parentPID), let parent = byPID[current.parentPID], steps < members.count {
                current = parent
                steps += 1
            }
            return current.identity
        }
        return Array(Set(members.filter { wanted.contains(copyRoot(of: $0)) }.flatMap(\.forensics.listeningPorts))).sorted()
    }

    public func resolving(relatedFamilyKeys: [String], isInternalToSingleFamily: Bool) -> DuplicateProcessCluster {
        // Membership and measurements are unchanged. Reusing their immutable
        // projection avoids sorting members and rebuilding hints a second time.
        var resolved = self
        resolved.relatedFamilyKeys = relatedFamilyKeys.sorted()
        resolved.isInternalToSingleFamily = isInternalToSingleFamily
        return resolved
    }

    public var reason: String {
        if isInternalToSingleFamily {
            return "\(memberCount) matching descendants inside one family"
        }
        if independentRootCount > 1 {
            return "\(independentRootCount) independent copies"
        }
        return "\(memberCount) matching instances"
    }

    private static func uniqueHints(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }
}

public struct DuplicateClusterSet: Equatable, Sendable {
    public let clusters: [DuplicateProcessCluster]
    public let promotedIdentities: Set<ProcessIdentity>
    public let detectorMilliseconds: Double

    public static let empty = DuplicateClusterSet(
        clusters: [],
        promotedIdentities: [],
        detectorMilliseconds: 0
    )

    public init(
        clusters: [DuplicateProcessCluster],
        promotedIdentities: Set<ProcessIdentity>,
        detectorMilliseconds: Double
    ) {
        self.clusters = clusters
        self.promotedIdentities = promotedIdentities
        self.detectorMilliseconds = detectorMilliseconds
    }

    public var visibleClusters: [DuplicateProcessCluster] {
        clusters.filter { !$0.isInternalToSingleFamily }
    }
}

public struct DuplicateClusterViewModel: Identifiable, Equatable, Sendable {
    public var id: String { cluster.id }

    public let cluster: DuplicateProcessCluster
    public let title: String
    public let subtitle: String
    public let countText: String
    public let rootCountText: String
    public let memoryText: String
    public let cpuText: String
    public let kindText: String
    public let reasonText: String
    public let pidText: String

    public init(cluster: DuplicateProcessCluster) {
        self.cluster = cluster
        title = cluster.displayName
        subtitle = cluster.commandHints.first ?? cluster.pathHints.first ?? cluster.key.value
        countText = "\(cluster.memberCount)"
        rootCountText = "\(cluster.independentRootCount)"
        memoryText = RadarFormat.bytes(cluster.totalPhysicalFootprintBytes)
        cpuText = RadarFormat.percent(cluster.totalCPUPercent)
        kindText = cluster.likelyKind.label
        reasonText = cluster.reason
        pidText = cluster.representativePIDs.map(String.init).joined(separator: ", ")
    }

    public static func rows(from clusters: [DuplicateProcessCluster]) -> [DuplicateClusterViewModel] {
        clusters
            .filter { !$0.isInternalToSingleFamily }
            .map(DuplicateClusterViewModel.init(cluster:))
            .sorted { lhs, rhs in
                if lhs.cluster.memberCount != rhs.cluster.memberCount {
                    return lhs.cluster.memberCount > rhs.cluster.memberCount
                }
                if lhs.cluster.totalPhysicalFootprintBytes != rhs.cluster.totalPhysicalFootprintBytes {
                    return lhs.cluster.totalPhysicalFootprintBytes > rhs.cluster.totalPhysicalFootprintBytes
                }
                if lhs.cluster.totalCPUPercent != rhs.cluster.totalCPUPercent {
                    return lhs.cluster.totalCPUPercent > rhs.cluster.totalCPUPercent
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}

public struct DuplicateClusterDetailModel: Equatable, Sendable {
    public let title: String
    public let keyText: String
    public let captureReason: String
    public let commandHints: [String]
    public let pathHints: [String]
    public let pidGroups: [String]
    public let relatedFamilyKeys: [String]

    public init(cluster: DuplicateProcessCluster) {
        title = cluster.displayName
        keyText = "\(cluster.key.kind.rawValue): \(cluster.key.value)"
        captureReason = cluster.reason
        commandHints = cluster.commandHints
        pathHints = cluster.pathHints
        pidGroups = cluster.members.map { process in
            "PID \(process.pid) - \(RadarFormat.bytes(process.memoryForScoringBytes)), \(RadarFormat.percent(process.cpuPercent))"
        }
        relatedFamilyKeys = cluster.relatedFamilyKeys
    }
}
