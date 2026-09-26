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
    private let staticFacts = ProcessStaticFactsCache()
    private let duplicateDetector: DuplicateClusterDetector
    private let hardwareDetector: HardwareOffenderDetector
    private let evidenceScorer = FamilyEvidenceScorer()

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
        let tree = ProcessTree(processes: processes, facts: staticFacts.facts(for: processes, make: makeStaticFacts))

        let duplicateSet = duplicateDetector.detect(
            processes: processes,
            classifications: tree.classifications,
            byPID: tree.byPID,
            now: now,
            candidateKey: { tree.facts[$0.pid]?.duplicateKey }
        )
        let hardwareStart = Date()
        let hardwareProfiles = hardwareDetector.detect(
            processes: processes,
            settings: settings,
            isEligible: { tree.facts[$0.pid]?.isHardwareEligible ?? false }
        )
        let hardwareDetectorMilliseconds = Date().timeIntervalSince(hardwareStart) * 1_000
        let duplicatePromotedIdentities = duplicateSet.promotedIdentities

        var candidates: [ProcessMetrics] = []
        candidates.reserveCapacity(min(processes.count, 128))
        for process in processes {
            if shouldInclude(
                process,
                confidence: tree.confidence(process.pid),
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
                let candidateRoot = tree.root(for: candidate)
                let score = tree.confidence(candidateRoot.pid)
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

        // Membership first, so duplicates are resolved against the real
        // families before any family is scored against them.
        let rootIdentities = Set(roots.map(\.identity))
        let memberships = roots.compactMap { root -> (familyKey: String, root: ProcessMetrics, members: [ProcessMetrics])? in
            let members = tree.members(of: root, rootIdentities: rootIdentities)
            guard !members.isEmpty else { return nil }
            return (ProcessFamily.key(signature: signature(of: root, in: tree), root: root.identity), root, members)
        }
        let resolvedClusters = DuplicateFamilyResolver.resolve(
            duplicateSet.clusters,
            memberships: memberships.map { ($0.familyKey, $0.members) }
        )
        var clusterByIdentity: [ProcessIdentity: DuplicateProcessCluster] = [:]
        for cluster in resolvedClusters {
            for member in cluster.members {
                clusterByIdentity[member.identity] = cluster
            }
        }
        let parentFamilyKeys = tree.parentFamilyKeys(memberships)

        // Unordered: RadarPipeline ranks families after scoring.
        let families = memberships.map { membership in
            makeFamily(
                root: membership.root,
                members: membership.members,
                tree: tree,
                duplicateCluster: bestDuplicateCluster(for: membership.members, clustersByIdentity: clusterByIdentity),
                parentFamilyKey: parentFamilyKeys[membership.familyKey],
                hardwareProfiles: hardwareProfiles,
                settings: settings,
                trendWindow: &trendWindow,
                now: now
            )
        }
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
        RadarSummaryBuilder.summary(for: families)
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

    private func makeStaticFacts(for process: ProcessMetrics) -> ProcessStaticFacts {
        let tokens = WorkloadTokens(process)
        let classification = classifier.classification(for: tokens)
        return ProcessStaticFacts(
            classification: classification,
            signature: ProcessSignature.from(root: process),
            commandHint: ProcessStaticFacts.commandHint(of: process.commandLine),
            appBundlePrefix: ProcessStaticFacts.appBundlePrefix(of: process.executablePath),
            parentDirectory: ProcessStaticFacts.parentDirectory(of: process.executablePath),
            isHelperNamed: process.name.lowercased().contains("helper"),
            isAppMainBinary: tokens.isAppMainBinary,
            isHardwareEligible: hardwareDetector.isEligibleForGenericHardwareDetection(process),
            duplicateKey: duplicateDetector.candidateKey(for: process, tokens: tokens, classification: classification)
        )
    }

    private func signature(of root: ProcessMetrics, in tree: ProcessTree) -> ProcessSignature {
        tree.facts[root.pid]?.signature ?? ProcessSignature.from(root: root)
    }

    private func isAboveHardThreshold(_ process: ProcessMetrics, settings: ThresholdSettings) -> Bool {
        process.memoryForScoringBytes >= settings.memoryBytes || process.cpuPercent >= settings.cpuPercent
    }

    private func makeFamily(
        root: ProcessMetrics,
        members: [ProcessMetrics],
        tree: ProcessTree,
        duplicateCluster: DuplicateProcessCluster?,
        parentFamilyKey: String?,
        hardwareProfiles: [ProcessIdentity: HardwareOffenderProfile],
        settings: ThresholdSettings,
        trendWindow: inout TrendWindow,
        now: Date
    ) -> ProcessFamily {
        // Memory carries each member's last-known value; CPU and GPU count
        // only current readings, because a helper cached at 300% during a
        // build would otherwise read as a phantom runaway.
        let coverage = FamilyMeasurementCoverage(members: members, root: root, at: now)
        let resident = members.reduce(UInt64(0)) { $0 + $1.residentMemoryBytes }
        let footprint = members.reduce(UInt64(0)) { $0 + $1.memoryForScoringBytes }
        let cpu = members.reduce(0) { isCurrent($1.cpuMeasurementDate, at: now) ? $0 + $1.cpuPercent : $0 }
        let gpu = members.reduce(0) { isCurrent($1.gpuMeasurementDate, at: now) ? $0 + $1.gpuUsagePercent : $0 }
        let hardwareSignals = hardwareSignals(for: members, profiles: hardwareProfiles)
        let familyConfidence = members.map { tree.confidence($0.pid) }.max() ?? 0
        let familyClassification = familyClassification(root: root, members: members, facts: tree.facts, footprint: footprint, cpu: cpu, now: now)
        let signature = signature(of: root, in: tree)
        // Baselines intentionally learn by logical signature, but live trend
        // state must be isolated per concrete process-family instance. Two
        // identical servers running at once must never alternate samples into
        // one synthetic leak curve.
        let topology = members.map { "\($0.pid):\($0.identity.startTimeSeconds).\($0.identity.startTimeMicroseconds)" }.sorted().joined(separator: ",")
        let runtimeTrendKey = "\(signature.id)|members:\(topology)"
        let trend: TrendMetrics
        if coverage.memoryCoverage >= 0.9, let measuredAt = coverage.newestFreshMeasurement {
            trend = trendWindow.update(signatureID: runtimeTrendKey, memoryBytes: footprint, cpuPercent: cpu, at: measuredAt)
        } else {
            trend = .empty
        }
        let score = evidenceScorer.score(
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
            commandHints: tree.commandHints(for: members),
            trend: trend,
            score: score,
            ownedIdentities: owned,
            protectedPIDs: protected,
            signature: signature,
            classification: familyClassification,
            duplicateCluster: duplicateCluster,
            hardwareSignals: hardwareSignals,
            coverage: coverage,
            parentFamilyKey: parentFamilyKey
        )
    }

    /// The root says what a family is. A member that holds most of the
    /// family's footprint and CPU this tick names it instead; that changes
    /// only the label, never membership.
    private func familyClassification(
        root: ProcessMetrics,
        members: [ProcessMetrics],
        facts: [Int32: ProcessStaticFacts],
        footprint: UInt64,
        cpu: Double,
        now: Date
    ) -> DevClassification? {
        let rootClassification = facts[root.pid]?.classification
        guard members.count > 1, footprint > 0 else { return rootClassification }
        for member in members where member.identity != root.identity {
            let memoryShare = Double(member.memoryForScoringBytes) / Double(footprint)
            let memberCPU = isCurrent(member.cpuMeasurementDate, at: now) ? member.cpuPercent : 0
            let cpuShare = cpu >= 1 ? memberCPU / cpu : 1
            if memoryShare >= 0.6, cpuShare >= 0.6, let dominant = facts[member.pid]?.classification {
                return dominant
            }
        }
        return rootClassification
    }

    private func isCurrent(_ measuredAt: Date?, at now: Date) -> Bool {
        measuredAt.map { (0...FamilyMeasurementCoverage.maximumAge).contains(now.timeIntervalSince($0)) } ?? false
    }

    private func bestDuplicateCluster(
        for members: [ProcessMetrics],
        clustersByIdentity: [ProcessIdentity: DuplicateProcessCluster]
    ) -> DuplicateProcessCluster? {
        // Independent copies are what the score is about; an internal pool
        // is shown only when the family is in no such cluster.
        members
            .compactMap { clustersByIdentity[$0.identity] }
            .max { lhs, rhs in
                if lhs.countsAsIndependentCopies != rhs.countsAsIndependentCopies { return rhs.countsAsIndependentCopies }
                if lhs.memberCount != rhs.memberCount { return lhs.memberCount < rhs.memberCount }
                return lhs.totalPhysicalFootprintBytes < rhs.totalPhysicalFootprintBytes
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
}
