import Darwin
import Foundation

public struct ProcessFamilyBuildResult: Sendable {
    public let families: [ProcessFamily]
    public let duplicateClusters: [DuplicateProcessCluster]
    public let promotedDuplicateCandidateCount: Int
    public let duplicateDetectorMilliseconds: Double
    public let hardwareOffenderCount: Int
    public let hardwareDetectorMilliseconds: Double

    public static let empty = ProcessFamilyBuildResult(
        families: [],
        duplicateClusters: [],
        promotedDuplicateCandidateCount: 0,
        duplicateDetectorMilliseconds: 0,
        hardwareOffenderCount: 0,
        hardwareDetectorMilliseconds: 0
    )

    public init(
        families: [ProcessFamily],
        duplicateClusters: [DuplicateProcessCluster],
        promotedDuplicateCandidateCount: Int,
        duplicateDetectorMilliseconds: Double,
        hardwareOffenderCount: Int = 0,
        hardwareDetectorMilliseconds: Double = 0
    ) {
        self.families = families
        self.duplicateClusters = duplicateClusters
        self.promotedDuplicateCandidateCount = promotedDuplicateCandidateCount
        self.duplicateDetectorMilliseconds = duplicateDetectorMilliseconds
        self.hardwareOffenderCount = hardwareOffenderCount
        self.hardwareDetectorMilliseconds = hardwareDetectorMilliseconds
    }
}

public struct ProcessFamilyBuilder: Sendable {
    private let classifier: DevProcessClassifier
    private let currentUserID: UInt32
    private let classificationCache = LockedDevClassificationCache()
    private let duplicateDetector: DuplicateClusterDetector
    private let hardwareDetector: HardwareOffenderDetector

    public init(
        classifier: DevProcessClassifier = DevProcessClassifier(),
        currentUserID: UInt32 = UInt32(geteuid())
    ) {
        self.classifier = classifier
        self.currentUserID = currentUserID
        self.duplicateDetector = DuplicateClusterDetector(classifier: classifier, currentUserID: currentUserID)
        self.hardwareDetector = HardwareOffenderDetector(currentUserID: currentUserID)
    }

    public func buildFamilies(
        from processes: [ProcessMetrics],
        settings: ThresholdSettings,
        trendWindow: inout TrendWindow,
        now: Date
    ) -> [ProcessFamily] {
        buildFamiliesWithDuplicates(
            from: processes,
            settings: settings,
            trendWindow: &trendWindow,
            now: now
        ).families
    }

    public func buildFamiliesWithDuplicates(
        from processes: [ProcessMetrics],
        settings: ThresholdSettings,
        trendWindow: inout TrendWindow,
        now: Date
    ) -> ProcessFamilyBuildResult {
        var byPID: [Int32: ProcessMetrics] = [:]
        var children: [Int32: [ProcessMetrics]] = [:]
        var classifications: [Int32: DevClassification] = [:]
        var confidence: [Int32: Double] = [:]
        var candidates: [ProcessMetrics] = []
        byPID.reserveCapacity(processes.count)
        children.reserveCapacity(processes.count / 2)
        classifications.reserveCapacity(processes.count)
        confidence.reserveCapacity(processes.count)
        candidates.reserveCapacity(min(processes.count, 128))

        for process in processes {
            byPID[process.pid] = process
            children[process.parentPID, default: []].append(process)
            let classification = classification(for: process)
            classifications[process.pid] = classification
            confidence[process.pid] = classification.confidence
        }

        let duplicateSet = duplicateDetector.detect(
            processes: processes,
            classifications: classifications,
            children: children,
            now: now
        )
        let hardwareStart = Date()
        let hardwareProfiles = hardwareDetector.detect(processes: processes, settings: settings)
        let hardwareDetectorMilliseconds = Date().timeIntervalSince(hardwareStart) * 1_000
        let duplicatePromotedIdentities = duplicateSet.promotedIdentities
        var duplicateClusterByIdentity: [ProcessIdentity: DuplicateProcessCluster] = [:]
        for cluster in duplicateSet.clusters {
            for member in cluster.members {
                duplicateClusterByIdentity[member.identity] = cluster
            }
        }

        for process in processes {
            if shouldInclude(
                process,
                confidence: confidence[process.pid, default: 0],
                hardwareProfile: hardwareProfiles[process.identity],
                settings: settings
            ) ||
                duplicatePromotedIdentities.contains(process.identity) {
                candidates.append(process)
            }
        }

        let roots: [ProcessMetrics]
        if settings.groupFamilies {
            var rootBuckets: [ProcessIdentity: (root: ProcessMetrics, score: Double)] = [:]
            rootBuckets.reserveCapacity(candidates.count)
            for candidate in candidates {
                let candidateRoot = root(for: candidate, byPID: byPID, confidence: confidence)
                let score = confidence[candidateRoot.pid, default: 0]
                if let existing = rootBuckets[candidateRoot.identity] {
                    if score > existing.score ||
                        (score == existing.score && candidateRoot.memoryForScoringBytes > existing.root.memoryForScoringBytes) {
                        rootBuckets[candidateRoot.identity] = (candidateRoot, score)
                    }
                } else {
                    rootBuckets[candidateRoot.identity] = (candidateRoot, score)
                }
            }
            roots = rootBuckets.values.map(\.root)
        } else {
            roots = candidates
        }

        let builtFamilies = roots
            .compactMap { makeFamily(root: $0, byPID: byPID, children: children, classifications: classifications, confidence: confidence, duplicateClusterByIdentity: duplicateClusterByIdentity, hardwareProfiles: hardwareProfiles, settings: settings, trendWindow: &trendWindow, now: now) }
            .sorted(by: sortFamilies)
        let resolvedClusters = resolveDuplicateClusters(duplicateSet.clusters, families: builtFamilies)
        var resolvedClusterByIdentity: [ProcessIdentity: DuplicateProcessCluster] = [:]
        for cluster in resolvedClusters {
            for member in cluster.members {
                resolvedClusterByIdentity[member.identity] = cluster
            }
        }
        let families = builtFamilies
            .map { family -> ProcessFamily in
                let cluster = bestDuplicateCluster(for: family.members, clustersByIdentity: resolvedClusterByIdentity)
                return family.enriched(duplicateCluster: cluster)
            }
            .sorted(by: sortFamilies)
        return ProcessFamilyBuildResult(
            families: families,
            duplicateClusters: resolvedClusters,
            promotedDuplicateCandidateCount: duplicatePromotedIdentities.count,
            duplicateDetectorMilliseconds: duplicateSet.detectorMilliseconds,
            hardwareOffenderCount: hardwareProfiles.count,
            hardwareDetectorMilliseconds: hardwareDetectorMilliseconds
        )
    }

    public func summary(for families: [ProcessFamily]) -> RadarSummary {
        let level = families.map { max($0.score.level, $0.forecast.state.level) }.max() ?? .quiet
        let hotCount = families.filter { $0.score.level >= .hot || $0.forecast.state >= .leaking }.count
        let leakingCount = families.filter { $0.trend.memoryVelocityMegabytesPerMinute > 0 || $0.forecast.state >= .leaking }.count
        let suggestionCount = families.reduce(0) { $0 + $1.suggestions.count }
        let totalMemory = families.reduce(UInt64(0)) { $0 + $1.totalPhysicalFootprintBytes }
        let top = families.first

        let statusText: String
        if let topForecast = families.first(where: { $0.forecast.state >= .leaking }) {
            statusText = topForecast.forecast.state == .leaking ? "Leak \(topForecast.forecast.etaText)" : topForecast.forecast.state.label
        } else if let topWarming = families.first(where: { $0.forecast.state == .warming }) {
            statusText = "Warming \(topWarming.forecast.etaText)"
        } else if let topLeak = families.first(where: { $0.trend.memoryVelocityMegabytesPerMinute >= 100 }) {
            statusText = "Leak \(Int(topLeak.trend.memoryVelocityMegabytesPerMinute.rounded())) MB/min"
        } else if let topGPU = families.first(where: { $0.totalGPUPercent >= 25 }) {
            statusText = "GPU \(Int(topGPU.totalGPUPercent.rounded()))%"
        } else if hotCount > 0 {
            statusText = "\(hotCount) hot"
        } else if let top, top.score.level == .watch {
            statusText = "Watching"
        } else if let top, top.totalPhysicalFootprintBytes > 0 {
            statusText = formatCompactBytes(top.totalPhysicalFootprintBytes)
        } else {
            statusText = "Quiet"
        }

        return RadarSummary(
            statusText: statusText,
            level: level,
            familyCount: families.count,
            hotCount: hotCount,
            totalMemoryBytes: totalMemory,
            topFamilyName: top?.displayName,
            leakingCount: leakingCount,
            suggestionCount: suggestionCount
        )
    }

    private func shouldInclude(_ process: ProcessMetrics, confidence: Double, settings: ThresholdSettings) -> Bool {
        shouldInclude(process, confidence: confidence, hardwareProfile: nil, settings: settings)
    }

    private func shouldInclude(
        _ process: ProcessMetrics,
        confidence: Double,
        hardwareProfile: HardwareOffenderProfile?,
        settings: ThresholdSettings
    ) -> Bool {
        let hardwarePromoted = hardwareProfile?.shouldPromote == true
        switch settings.radarMode {
        case .dev:
            return confidence >= 0.35 || hardwarePromoted || isAboveHardThreshold(process, settings: settings)
        case .heavy:
            return confidence >= 0.35 || hardwarePromoted || process.memoryForScoringBytes >= settings.memoryBytes / 2 || process.cpuPercent >= settings.cpuPercent / 2
        case .all:
            return !process.isSystemProcess || confidence >= 0.2 || isAboveHardThreshold(process, settings: settings)
        }
    }

    private func classification(for process: ProcessMetrics) -> DevClassification {
        classificationCache.classification(for: process, classifier: classifier)
    }

    private func isAboveHardThreshold(_ process: ProcessMetrics, settings: ThresholdSettings) -> Bool {
        process.memoryForScoringBytes >= settings.memoryBytes || process.cpuPercent >= settings.cpuPercent
    }

    private func root(
        for process: ProcessMetrics,
        byPID: [Int32: ProcessMetrics],
        confidence: [Int32: Double]
    ) -> ProcessMetrics {
        var current = process
        var visited = Set<Int32>()

        while let parent = byPID[current.parentPID], !visited.contains(parent.pid) {
            visited.insert(current.pid)
            guard parent.userID == current.userID else {
                break
            }
            guard shouldClimb(from: current, to: parent, confidence: confidence) else {
                break
            }
            current = parent
        }

        return current
    }

    private func shouldClimb(
        from child: ProcessMetrics,
        to parent: ProcessMetrics,
        confidence: [Int32: Double]
    ) -> Bool {
        if confidence[parent.pid, default: 0] >= 0.35 {
            return true
        }
        if sameAppBundle(child.executablePath, parent.executablePath) {
            return true
        }
        if parent.name.lowercased().contains("helper") && samePathNeighborhood(child.executablePath, parent.executablePath) {
            return true
        }
        return false
    }

    private func makeFamily(
        root: ProcessMetrics,
        byPID: [Int32: ProcessMetrics],
        children: [Int32: [ProcessMetrics]],
        classifications: [Int32: DevClassification],
        confidence: [Int32: Double],
        duplicateClusterByIdentity: [ProcessIdentity: DuplicateProcessCluster],
        hardwareProfiles: [ProcessIdentity: HardwareOffenderProfile],
        settings: ThresholdSettings,
        trendWindow: inout TrendWindow,
        now: Date
    ) -> ProcessFamily? {
        let members = descendants(of: root, children: children)
            .filter { member in
                member.identity == root.identity ||
                member.userID == root.userID ||
                sameAppBundle(member.executablePath, root.executablePath) ||
                confidence[member.pid, default: 0] >= 0.2
            }
            .sorted { lhs, rhs in
                if lhs.identity == root.identity { return true }
                if rhs.identity == root.identity { return false }
                return lhs.pid < rhs.pid
            }

        guard !members.isEmpty else {
            return nil
        }

        let resident = members.reduce(UInt64(0)) { $0 + $1.residentMemoryBytes }
        let footprint = members.reduce(UInt64(0)) { $0 + $1.memoryForScoringBytes }
        let cpu = members.reduce(0) { $0 + $1.cpuPercent }
        let gpu = members.reduce(0) { $0 + $1.gpuUsagePercent }
        let hardwareSignals = hardwareSignals(for: members, profiles: hardwareProfiles)
        let familyConfidence = members.map { confidence[$0.pid, default: 0] }.max() ?? 0
        let familyClassification = members
            .compactMap { classifications[$0.pid] }
            .max { classificationPriority($0) < classificationPriority($1) }
        let duplicateCluster = bestDuplicateCluster(for: members, clustersByIdentity: duplicateClusterByIdentity)
        let signature = ProcessSignature.from(root: root)
        let trend = trendWindow.update(signatureID: signature.id, memoryBytes: footprint, cpuPercent: cpu, at: now)
        let score = ghostScore(
            root: root,
            members: members,
            footprint: footprint,
            cpu: cpu,
            gpu: gpu,
            confidence: familyConfidence,
            duplicateCluster: duplicateCluster,
            hardwareSignals: hardwareSignals,
            trend: trend,
            settings: settings,
            now: now
        )

        let owned = killOrder(for: members, root: root)
            .filter { $0.userID == currentUserID }
            .map(\.identity)
        let protected = members
            .filter { $0.userID != currentUserID }
            .map(\.pid)
            .sorted()

        return ProcessFamily(
            root: root,
            members: members,
            totalResidentMemoryBytes: resident,
            totalPhysicalFootprintBytes: footprint,
            totalCPUPercent: cpu,
            totalGPUPercent: gpu,
            devConfidence: familyConfidence,
            commandHints: commandHints(from: members),
            trend: trend,
            score: score,
            ownedIdentities: owned,
            protectedPIDs: protected,
            signature: signature,
            classification: familyClassification,
            duplicateCluster: duplicateCluster,
            hardwareSignals: hardwareSignals
        )
    }

    private func resolveDuplicateClusters(
        _ clusters: [DuplicateProcessCluster],
        families: [ProcessFamily]
    ) -> [DuplicateProcessCluster] {
        let familyIdentitySets = families.map { family in
            (familyKey: family.familyKey, identities: Set(family.members.map(\.identity)))
        }
        return clusters.map { cluster in
            let clusterIdentities = Set(cluster.members.map(\.identity))
            let related = familyIdentitySets.filter { family in
                !clusterIdentities.isDisjoint(with: family.identities)
            }
            let isInternal = related.contains { family in
                clusterIdentities.isSubset(of: family.identities)
            }
            return cluster.resolving(
                relatedFamilyKeys: related.map(\.familyKey),
                isInternalToSingleFamily: isInternal
            )
        }
        .sorted { lhs, rhs in
            if lhs.memberCount != rhs.memberCount { return lhs.memberCount > rhs.memberCount }
            if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes { return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes }
            return lhs.totalCPUPercent > rhs.totalCPUPercent
        }
    }

    private func bestDuplicateCluster(
        for members: [ProcessMetrics],
        clustersByIdentity: [ProcessIdentity: DuplicateProcessCluster]
    ) -> DuplicateProcessCluster? {
        members
            .compactMap { clustersByIdentity[$0.identity] }
            .max { lhs, rhs in
                if lhs.memberCount != rhs.memberCount { return lhs.memberCount < rhs.memberCount }
                return lhs.totalPhysicalFootprintBytes < rhs.totalPhysicalFootprintBytes
            }
    }

    private func descendants(of root: ProcessMetrics, children: [Int32: [ProcessMetrics]]) -> [ProcessMetrics] {
        var result: [ProcessMetrics] = []
        var stack = [root]
        var seen = Set<Int32>()

        while let process = stack.popLast() {
            guard seen.insert(process.pid).inserted else {
                continue
            }
            result.append(process)
            stack.append(contentsOf: children[process.pid, default: []])
        }

        return result
    }

    private func hardwareSignals(
        for members: [ProcessMetrics],
        profiles: [ProcessIdentity: HardwareOffenderProfile]
    ) -> [HardwareOffenderSignal] {
        var seen = Set<String>()
        return members
            .flatMap { profiles[$0.identity]?.signals ?? [] }
            .filter { signal in
                seen.insert("\(signal.kind.rawValue)|\(signal.reason)").inserted
            }
            .sorted { lhs, rhs in
                if lhs.level != rhs.level { return lhs.level > rhs.level }
                return lhs.impact > rhs.impact
            }
            .prefix(6)
            .map { $0 }
    }

    private func killOrder(for members: [ProcessMetrics], root: ProcessMetrics) -> [ProcessMetrics] {
        members.sorted { lhs, rhs in
            if lhs.identity == root.identity { return false }
            if rhs.identity == root.identity { return true }
            return lhs.pid > rhs.pid
        }
    }

    private func ghostScore(
        root: ProcessMetrics,
        members: [ProcessMetrics],
        footprint: UInt64,
        cpu: Double,
        gpu: Double,
        confidence: Double,
        duplicateCluster: DuplicateProcessCluster?,
        hardwareSignals: [HardwareOffenderSignal],
        trend: TrendMetrics,
        settings: ThresholdSettings,
        now: Date
    ) -> GhostScore {
        let memoryRatio = Double(footprint) / Double(max(settings.memoryBytes, 1))
        let cpuRatio = cpu / max(settings.cpuPercent, 1)
        let gpuRatio = gpu / 80
        let leakRatio = max(0, trend.memoryVelocityMegabytesPerMinute) / max(settings.leakVelocityMegabytesPerMinute, 1)
        let childFanout = max(0, members.count - 6)
        let duplicateImpact = duplicateCluster.map { min(12, Double($0.memberCount) * 3) } ?? 0
        let hardwareImpact = min(24, hardwareSignals.reduce(0) { $0 + $1.impact })
        let ageMinutes = max(0, now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(root.identity.startTimeSeconds))) / 60)
        let orphanBonus = root.parentPID == 1 && confidence >= 0.35 ? 6.0 : 0

        var reasons: [String] = []
        if memoryRatio >= 1 {
            reasons.append("memory above threshold")
        } else if memoryRatio >= 0.55 {
            reasons.append("large memory footprint")
        }
        if cpuRatio >= 1 {
            reasons.append("CPU above threshold")
        } else if cpuRatio >= 0.55 {
            reasons.append("CPU burst")
        }
        if gpuRatio >= 1 {
            reasons.append("GPU above threshold")
        } else if gpuRatio >= 0.25 {
            reasons.append("GPU activity \(RadarFormat.percent(gpu))")
        }
        if leakRatio >= 1 {
            reasons.append("memory climbing \(Int(trend.memoryVelocityMegabytesPerMinute.rounded())) MB/min")
        }
        for signal in hardwareSignals.prefix(3) where !reasons.contains(signal.reason) {
            reasons.append(signal.reason)
        }
        if childFanout > 0 {
            reasons.append("\(members.count - 1) child processes")
        }
        if let duplicateCluster {
            reasons.append("\(duplicateCluster.memberCount) matching instances")
        }
        if orphanBonus > 0 {
            reasons.append("background dev process")
        }
        if ageMinutes > 180, confidence >= 0.45 {
            reasons.append("long-running dev session")
        }
        if reasons.isEmpty {
            reasons.append(confidence >= 0.45 ? "dev process is quiet" : "low activity")
        }

        let value = min(
            100,
            memoryRatio * 38 +
            cpuRatio * 34 +
            gpuRatio * 28 +
            leakRatio * 26 +
            Double(childFanout) * 3 +
            duplicateImpact +
            hardwareImpact +
            confidence * 12 +
            orphanBonus +
            (ageMinutes > 180 ? 5 : 0)
        )

        let level: GhostLevel
        let hardwareLevel = hardwareSignals.map(\.level).max() ?? .quiet
        if memoryRatio >= 1.25 || cpuRatio >= 1.15 || gpuRatio >= 1 || leakRatio >= 1.6 || hardwareLevel == .critical || value >= 82 {
            level = .critical
        } else if memoryRatio >= 1 || cpuRatio >= 1 || gpuRatio >= 0.55 || leakRatio >= 1 || hardwareLevel == .hot || value >= 58 {
            level = .hot
        } else if value >= 26 || confidence >= 0.45 || hardwareLevel >= .watch {
            level = .watch
        } else if duplicateCluster != nil {
            level = .watch
        } else {
            level = .quiet
        }

        return GhostScore(value: value, level: level, reasons: reasons)
    }

    private func commandHints(from members: [ProcessMetrics]) -> [String] {
        var hints: [String] = []

        for process in members {
            if let hint = commandHint(from: process.commandLine) {
                hints.append(hint)
            }
        }

        var seen = Set<String>()
        return hints.filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }

    private func commandHint(from command: String) -> String? {
        var scannedPieces = 0
        for piece in command.split(whereSeparator: \.isWhitespace) {
            scannedPieces += 1
            guard scannedPieces <= 16 else {
                break
            }
            let lower = piece.lowercased()
            if lower.contains("node_modules") ||
                lower.hasSuffix("vite") ||
                lower.hasSuffix("next") ||
                lower.hasSuffix("ollama") ||
                lower.hasSuffix("python") ||
                lower.hasSuffix("python3") ||
                lower.hasSuffix("bun") ||
                lower.hasSuffix("docker") {
                return lastPathComponent(String(piece))
            }
        }
        return nil
    }

    private func lastPathComponent(_ value: String) -> String {
        if let slash = value.lastIndex(of: "/") {
            return String(value[value.index(after: slash)...])
        }
        return value
    }

    private func sortFamilies(_ lhs: ProcessFamily, _ rhs: ProcessFamily) -> Bool {
        if lhs.forecast.state != rhs.forecast.state {
            return lhs.forecast.state > rhs.forecast.state
        }
        if lhs.score.level != rhs.score.level {
            return lhs.score.level > rhs.score.level
        }
        if lhs.score.value != rhs.score.value {
            return lhs.score.value > rhs.score.value
        }
        if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes {
            return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes
        }
        if lhs.totalCPUPercent != rhs.totalCPUPercent {
            return lhs.totalCPUPercent > rhs.totalCPUPercent
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private func classificationPriority(_ classification: DevClassification) -> Double {
        let kindBoost: Double = switch classification.kind {
        case .unknownHeavy:
            0
        case .cliTool:
            0.03
        case .electronApp, .localModelRunner, .dockerHelper:
            0.2
        default:
            0.12
        }
        return classification.confidence + kindBoost
    }

    private func sameAppBundle(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = appBundlePrefix(lhs), let right = appBundlePrefix(rhs) else {
            return false
        }
        return left == right
    }

    private func samePathNeighborhood(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).deletingLastPathComponent().path
        let right = URL(fileURLWithPath: rhs).deletingLastPathComponent().path
        return !left.isEmpty && left == right
    }

    private func appBundlePrefix(_ path: String) -> String? {
        guard let range = path.range(of: ".app/", options: [.caseInsensitive]) else {
            return nil
        }
        return String(path[..<range.upperBound]).lowercased()
    }

    private func formatCompactBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        }
        return "\(max(1, Int(Double(bytes) / 1_048_576))) MB"
    }
}

private final class LockedDevClassificationCache: @unchecked Sendable {
    private struct Entry {
        var fingerprint: UInt64
        var classification: DevClassification
    }

    private let lock = NSLock()
    private var entries: [ProcessIdentity: Entry] = [:]
    private var pruneCounter = 0

    func classification(for process: ProcessMetrics, classifier: DevProcessClassifier) -> DevClassification {
        let fingerprint = Self.fingerprint(for: process)
        lock.lock()
        if let entry = entries[process.identity], entry.fingerprint == fingerprint {
            lock.unlock()
            return entry.classification
        }
        lock.unlock()

        let classification = classifier.classification(for: process)
        lock.lock()
        entries[process.identity] = Entry(fingerprint: fingerprint, classification: classification)
        pruneCounter += 1
        if pruneCounter >= 2_048, entries.count > 12_000 {
            let keep = Set(entries.keys.suffix(8_000))
            entries = entries.filter { keep.contains($0.key) }
            pruneCounter = 0
        }
        lock.unlock()
        return classification
    }

    private static func fingerprint(for process: ProcessMetrics) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(process.name)
        hasher.combine(process.executablePath)
        hasher.combine(process.commandLine)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
