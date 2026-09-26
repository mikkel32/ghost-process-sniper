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

        let rootIdentities = Set(roots.map(\.identity))

        let builtFamilies = roots
            .compactMap {
                makeFamily(
                    root: $0,
                    byPID: byPID,
                    children: children,
                    classifications: classifications,
                    confidence: confidence,
                    rootIdentities: rootIdentities,
                    duplicateClusterByIdentity: duplicateClusterByIdentity,
                    hardwareProfiles: hardwareProfiles,
                    settings: settings,
                    trendWindow: &trendWindow,
                    now: now
                )
            }
            .sorted(by: sortFamilies)
        let resolvedClusters = DuplicateFamilyResolver.resolve(duplicateSet.clusters, families: builtFamilies)
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
        // Resolving cluster ownership changes none of the family sort keys.
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
        let level = families.map { family in
            family.forecastIsCredibleEscalation
                ? max(family.score.level, family.forecast.state.level)
                : family.score.level
        }.max() ?? .quiet
        let hotCount = families.filter { $0.score.level >= .hot || $0.forecastIsCredibleEscalation }.count
        let leakingCount = families.filter {
            $0.forecastIsCredibleEscalation && $0.forecast.state >= .leaking
        }.count
        let suggestionCount = families.reduce(0) { $0 + $1.suggestions.count }
        let totalMemory = families.reduce(UInt64(0)) { $0 + $1.totalPhysicalFootprintBytes }
        let top = families.first

        let statusText: String
        if let topForecast = families.first(where: { $0.forecastIsCredibleEscalation }) {
            statusText = topForecast.forecast.state == .leaking ? "Leak \(topForecast.forecast.etaText)" : topForecast.forecast.state.label
        } else if let topWarming = families.first(where: { $0.forecastIsCredibleEarlyWarning }) {
            statusText = "Warming \(topWarming.forecast.etaText)"
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
        rootIdentities: Set<ProcessIdentity>,
        duplicateClusterByIdentity: [ProcessIdentity: DuplicateProcessCluster],
        hardwareProfiles: [ProcessIdentity: HardwareOffenderProfile],
        settings: ThresholdSettings,
        trendWindow: inout TrendWindow,
        now: Date
    ) -> ProcessFamily? {
        let members = familyMembers(
            of: root,
            children: children,
            confidence: confidence,
            rootIdentities: rootIdentities
        )

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
        // Baselines intentionally learn by logical signature, but live trend
        // state must be isolated per concrete process-family instance. Two
        // identical servers running at once must never alternate samples into
        // one synthetic leak curve.
        let topology = members.map { "\($0.pid):\($0.identity.startTimeSeconds).\($0.identity.startTimeMicroseconds)" }.sorted().joined(separator: ",")
        let runtimeTrendKey = "\(signature.id)|members:\(topology)"
        let measurementDates = members.compactMap(\.measurementDate)
        let oldestMeasurement = measurementDates.min()
        let hasCompleteSample = measurementDates.count == members.count && !members.isEmpty
        let trend: TrendMetrics
        if hasCompleteSample, let measuredAt = oldestMeasurement, now.timeIntervalSince(measuredAt) <= 15, now >= measuredAt {
            trend = trendWindow.update(signatureID: runtimeTrendKey, memoryBytes: footprint, cpuPercent: cpu, at: measuredAt)
        } else {
            trend = .empty
        }
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

    private func familyMembers(
        of root: ProcessMetrics,
        children: [Int32: [ProcessMetrics]],
        confidence: [Int32: Double],
        rootIdentities: Set<ProcessIdentity>
    ) -> [ProcessMetrics] {
        var result: [ProcessMetrics] = []
        var stack = [root]
        var seen = Set<Int32>()
        let rootIsDevFamily = confidence[root.pid, default: 0] >= 0.35

        while let process = stack.popLast() {
            guard seen.insert(process.pid).inserted else {
                continue
            }
            result.append(process)
            for child in children[process.pid, default: []] {
                guard child.userID == root.userID else {
                    continue
                }
                // Candidate roots are exclusive ownership boundaries. Without
                // this, one hot/helper root can repeatedly absorb and traverse
                // another family, producing overlapping trees and O(n²)-like
                // behavior on large process populations.
                guard child.identity == root.identity || !rootIdentities.contains(child.identity) else {
                    continue
                }
                let related = rootIsDevFamily ||
                    confidence[child.pid, default: 0] >= 0.2 ||
                    sameAppBundle(child.executablePath, root.executablePath) ||
                    samePathNeighborhood(child.executablePath, root.executablePath)
                guard related else {
                    continue
                }
                stack.append(child)
            }
        }

        return result.sorted { lhs, rhs in
            if lhs.identity == root.identity { return true }
            if rhs.identity == root.identity { return false }
            return lhs.pid < rhs.pid
        }
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

        let memoryImpact = memoryRatio * 38
        let cpuImpact = cpuRatio * 34
        let gpuImpact = gpuRatio * 28
        let leakImpact = leakRatio * 26
        let fanoutImpact = Double(childFanout) * 3
        let confidenceImpact = confidence * 12
        let ageImpact = ageMinutes > 180 ? 5.0 : 0

        func componentLevel(_ ratio: Double, hot: Double = 1, critical: Double = 1.25) -> GhostLevel {
            if ratio >= critical { return .critical }
            if ratio >= hot { return .hot }
            if ratio >= 0.45 { return .watch }
            return .quiet
        }

        var components: [GhostScoreComponent] = [
            GhostScoreComponent(
                kind: .memory,
                title: memoryRatio >= 1 ? "memory above threshold" : "Memory footprint",
                detail: String(
                    format: "%@ is %.1fx the %@ limit",
                    RadarFormat.bytes(footprint),
                    memoryRatio,
                    RadarFormat.bytes(settings.memoryBytes)
                ),
                impact: memoryImpact,
                level: componentLevel(memoryRatio)
            ),
            GhostScoreComponent(
                kind: .cpu,
                title: cpuRatio >= 1 ? "CPU above threshold" : "CPU activity",
                detail: String(format: "%.0f%% is %.1fx the %.0f%% limit", cpu, cpuRatio, settings.cpuPercent),
                impact: cpuImpact,
                level: componentLevel(cpuRatio, critical: 1.15)
            ),
            GhostScoreComponent(
                kind: .gpu,
                title: gpuRatio >= 1 ? "GPU above threshold" : "GPU activity",
                detail: String(format: "%.0f%% GPU utilization", gpu),
                impact: gpuImpact,
                level: componentLevel(gpuRatio, hot: 0.55, critical: 1)
            ),
            GhostScoreComponent(
                kind: .leak,
                title: leakRatio >= 1 ? "memory climbing \(Int(trend.memoryVelocityMegabytesPerMinute.rounded())) MB/min" : "Memory growth",
                detail: String(
                    format: "%.0f MB/min is %.1fx the %.0f MB/min limit",
                    max(0, trend.memoryVelocityMegabytesPerMinute),
                    leakRatio,
                    settings.leakVelocityMegabytesPerMinute
                ),
                impact: leakImpact,
                level: componentLevel(leakRatio, critical: 1.6)
            ),
            GhostScoreComponent(
                kind: .background,
                title: "Process relevance",
                detail: "\(Int((confidence * 100).rounded()))% confidence this belongs to the selected radar scope",
                impact: confidenceImpact,
                level: confidence >= 0.65 ? .watch : .quiet
            )
        ]

        if fanoutImpact > 0 {
            components.append(GhostScoreComponent(
                kind: .fanout,
                title: "\(members.count - 1) child processes",
                detail: "Large process trees consume more resources and are harder to leave behind cleanly",
                impact: fanoutImpact,
                level: childFanout >= 6 ? .hot : .watch
            ))
        }
        if let duplicateCluster, duplicateImpact > 0 {
            components.append(GhostScoreComponent(
                kind: .fanout,
                title: "\(duplicateCluster.memberCount) matching instances",
                detail: duplicateCluster.reason,
                impact: duplicateImpact,
                level: duplicateCluster.memberCount >= 4 ? .hot : .watch
            ))
        }
        if orphanBonus > 0 {
            components.append(GhostScoreComponent(
                kind: .background,
                title: "background dev process",
                detail: "Detached from its original parent and still running in the background",
                impact: orphanBonus,
                level: .watch
            ))
        }
        if ageImpact > 0 {
            components.append(GhostScoreComponent(
                kind: .background,
                title: "long-running dev session",
                detail: "This process family has been alive for more than three hours",
                impact: ageImpact,
                level: .watch
            ))
        }

        if hardwareImpact > 0 {
            let rawHardwareImpact = hardwareSignals.reduce(0) { $0 + $1.impact }
            let hardwareScale = rawHardwareImpact > 0 ? hardwareImpact / rawHardwareImpact : 0
            components.append(contentsOf: hardwareSignals.map { signal in
                let kind: GhostScoreComponentKind = switch signal.kind {
                case .memoryPressure: .memory
                case .cpuPressure: .cpu
                case .gpuPressure: .gpu
                case .threadPressure, .sampleOutlier: .system
                }
                return GhostScoreComponent(
                    kind: kind,
                    title: signal.reason,
                    detail: "Host-wide offender evidence: \(signal.kind.label.lowercased())",
                    impact: signal.impact * hardwareScale,
                    level: signal.level
                )
            })
        }

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

        let value = min(100, components.reduce(0) { $0 + $1.impact })

        let hardwareLevel = hardwareSignals.map(\.level).max() ?? .quiet
        var heat = GhostHeatModel.initial(
            memoryRatio: memoryRatio,
            cpuRatio: cpuRatio,
            gpuRatio: gpuRatio,
            leakRatio: leakRatio,
            trend: trend,
            hardwareLevel: hardwareLevel
        )
        if let duplicateCluster, heat.level == .quiet {
            heat = GhostHeat(
                value: max(30, heat.value),
                level: .watch,
                confidence: max(0.5, heat.confidence),
                evidence: heat.evidence + ["\(duplicateCluster.memberCount) independent matching instances need review"],
                sustainedSignalCount: heat.sustainedSignalCount
            )
        }

        return GhostScore(
            value: value,
            level: heat.level,
            reasons: reasons,
            components: GhostScoreComponentMath.normalized(components, to: value),
            heat: heat
        )
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
        if lhs.score.heat.value != rhs.score.heat.value {
            return lhs.score.heat.value > rhs.score.heat.value
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
