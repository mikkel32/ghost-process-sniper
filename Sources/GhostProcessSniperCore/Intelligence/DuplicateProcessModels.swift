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

    public init(
        key: DuplicateClusterKey,
        displayName: String,
        members: [ProcessMetrics],
        independentRootCount: Int,
        likelyKind: DevProcessKind,
        classificationReason: String,
        relatedFamilyKeys: [String] = [],
        isInternalToSingleFamily: Bool = false
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
            return "\(independentRootCount) independent matching roots"
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

public struct DuplicateClusterDetector: Sendable {
    private let classifier: DevProcessClassifier
    private let currentUserID: UInt32
    private let minimumClusterSize: Int

    public init(
        classifier: DevProcessClassifier = DevProcessClassifier(),
        currentUserID: UInt32 = UInt32(geteuid()),
        minimumClusterSize: Int = 2
    ) {
        self.classifier = classifier
        self.currentUserID = currentUserID
        self.minimumClusterSize = max(2, minimumClusterSize)
    }

    public func detect(
        processes: [ProcessMetrics],
        classifications: [Int32: DevClassification],
        children: [Int32: [ProcessMetrics]] = [:],
        now: Date = Date(),
        candidateKey: ((ProcessMetrics) -> DuplicateClusterKey?)? = nil
    ) -> DuplicateClusterSet {
        let started = Date()
        var buckets: [DuplicateClusterKey: [ProcessMetrics]] = [:]
        buckets.reserveCapacity(processes.count / 2)

        for process in processes {
            let key: DuplicateClusterKey?
            if let candidateKey {
                key = candidateKey(process)
            } else {
                key = self.candidateKey(for: process, classification: classifications[process.pid] ?? classifier.classification(for: process))
            }
            guard let key else {
                continue
            }
            buckets[key, default: []].append(process)
        }

        var clusters: [DuplicateProcessCluster] = []
        clusters.reserveCapacity(buckets.count)
        for (key, members) in buckets where members.count >= minimumClusterSize {
            let classifications = members.map { process in
                classifications[process.pid] ?? classifier.classification(for: process)
            }
            let bestClassification = classifications.max { lhs, rhs in
                lhs.groupingPriority < rhs.groupingPriority
            } ?? DevClassification(kind: .cliTool, confidence: 0.2, reason: "matching executable")
            let independentRoots = independentRootCount(for: members, children: children)
            clusters.append(
                DuplicateProcessCluster(
                    key: key,
                    displayName: key.displayName,
                    members: members,
                    independentRootCount: independentRoots,
                    likelyKind: bestClassification.kind,
                    classificationReason: bestClassification.reason
                )
            )
        }

        let sorted = clusters.sorted(by: Self.sortClusters)
        return DuplicateClusterSet(
            clusters: sorted,
            promotedIdentities: Set(sorted.flatMap { $0.members.map(\.identity) }),
            detectorMilliseconds: Date().timeIntervalSince(started) * 1_000
        )
    }

    /// The cluster key, or nil when the process is not a duplicate candidate.
    /// It depends only on static process facts, so callers may cache it.
    func candidateKey(for process: ProcessMetrics, classification: DevClassification) -> DuplicateClusterKey? {
        shouldConsider(process, classification: classification) ? key(for: process) : nil
    }

    private func shouldConsider(_ process: ProcessMetrics, classification: DevClassification) -> Bool {
        guard process.userID == currentUserID else {
            return false
        }
        guard !process.isSystemProcess else {
            return false
        }
        if isSystemBundle(process.executablePath) {
            return false
        }
        if classification.confidence >= 0.2 {
            return true
        }
        if process.executablePath.hasPrefix("/Users/") ||
            process.executablePath.hasPrefix("/opt/homebrew/") ||
            process.executablePath.hasPrefix("/usr/local/") {
            return true
        }
        return process.executablePath.isEmpty && !process.commandLine.isEmpty
    }

    private func key(for process: ProcessMetrics) -> DuplicateClusterKey? {
        let path = normalizedPath(process.executablePath)
        if !path.isEmpty {
            return DuplicateClusterKey(
                kind: .executablePath,
                value: path,
                displayName: path.split(separator: "/").last.map(String.init)?.ifNotEmpty ?? process.name
            )
        }
        let name = normalizedToken(process.name)
        guard !name.isEmpty else {
            return nil
        }
        let prefix = commandPrefix(process.commandLine)
        let value = prefix.isEmpty ? name : "\(name)|\(prefix)"
        return DuplicateClusterKey(kind: .commandPrefix, value: value, displayName: process.name)
    }

    private func independentRootCount(for members: [ProcessMetrics], children: [Int32: [ProcessMetrics]]) -> Int {
        let memberPIDs = Set(members.map(\.pid))
        let roots = members.filter { member in
            !memberPIDs.contains(member.parentPID)
        }
        return max(1, roots.count)
    }

    private func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func commandPrefix(_ command: String) -> String {
        command
            .split(whereSeparator: \.isWhitespace)
            .prefix(4)
            .map { piece in
                let token = String(piece).lowercased()
                if token.range(of: #"^\d+$"#, options: .regularExpression) != nil {
                    return "<num>"
                }
                if token.hasPrefix("/private/var/") || token.hasPrefix("/var/folders/") {
                    return "<tmp>"
                }
                return token
            }
            .joined(separator: " ")
    }

    private func isSystemBundle(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("/system/") ||
            lower.hasPrefix("/usr/libexec/") ||
            lower.hasPrefix("/library/apple/") ||
            lower.hasPrefix("/applications/") && !lower.contains("visual studio code") && !lower.contains("cursor") && !lower.contains("codex")
    }

    private static func sortClusters(_ lhs: DuplicateProcessCluster, _ rhs: DuplicateProcessCluster) -> Bool {
        if lhs.memberCount != rhs.memberCount {
            return lhs.memberCount > rhs.memberCount
        }
        if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes {
            return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes
        }
        if lhs.totalCPUPercent != rhs.totalCPUPercent {
            return lhs.totalCPUPercent > rhs.totalCPUPercent
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
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
