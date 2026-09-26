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
        var byPID: [Int32: ProcessMetrics] = [:]
        var children: [Int32: [ProcessMetrics]] = [:]
        var facts: [Int32: ProcessStaticFacts] = [:]
        var classifications: [Int32: DevClassification] = [:]
        var confidence: [Int32: Double] = [:]
        var candidates: [ProcessMetrics] = []
        byPID.reserveCapacity(processes.count)
        children.reserveCapacity(processes.count / 2)
        facts.reserveCapacity(processes.count)
        classifications.reserveCapacity(processes.count)
        confidence.reserveCapacity(processes.count)
        candidates.reserveCapacity(min(processes.count, 128))

        let staticFacts = staticFacts.facts(for: processes, make: makeStaticFacts)
        for (process, processFacts) in zip(processes, staticFacts) {
            byPID[process.pid] = process
            children[process.parentPID, default: []].append(process)
            facts[process.pid] = processFacts
            classifications[process.pid] = processFacts.classification
            confidence[process.pid] = processFacts.classification.confidence
        }

        let duplicateSet = duplicateDetector.detect(
            processes: processes,
            classifications: classifications,
            children: children,
            now: now,
            candidateKey: { facts[$0.pid]?.duplicateKey }
        )
        let hardwareStart = Date()
        let hardwareProfiles = hardwareDetector.detect(
            processes: processes,
            settings: settings,
            isEligible: { facts[$0.pid]?.isHardwareEligible ?? false }
        )
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
                let candidateRoot = root(for: candidate, byPID: byPID, facts: facts, confidence: confidence)
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
                    facts: facts,
                    confidence: confidence,
                    rootIdentities: rootIdentities,
                    duplicateClusterByIdentity: duplicateClusterByIdentity,
                    hardwareProfiles: hardwareProfiles,
                    settings: settings,
                    trendWindow: &trendWindow,
                    now: now
                )
            }
        // Unordered: RadarPipeline ranks families after scoring.
        let linkedFamilies = Self.linkingParentFamilies(builtFamilies, byPID: byPID)
        let resolvedClusters = DuplicateFamilyResolver.resolve(duplicateSet.clusters, families: linkedFamilies)
        var resolvedClusterByIdentity: [ProcessIdentity: DuplicateProcessCluster] = [:]
        for cluster in resolvedClusters {
            for member in cluster.members {
                resolvedClusterByIdentity[member.identity] = cluster
            }
        }
        let families = linkedFamilies
            .map { family -> ProcessFamily in
                let cluster = bestDuplicateCluster(for: family.members, clustersByIdentity: resolvedClusterByIdentity)
                return family.enriched(duplicateCluster: cluster)
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

    /// Marks each family whose root was launched by a member of another
    /// family, e.g. a language server started by an editor.
    static func linkingParentFamilies(_ families: [ProcessFamily], byPID: [Int32: ProcessMetrics]) -> [ProcessFamily] {
        var owner: [ProcessIdentity: String] = [:]
        owner.reserveCapacity(families.reduce(0) { $0 + $1.members.count })
        for family in families {
            for member in family.members {
                owner[member.identity] = family.familyKey
            }
        }
        return families.map { family in
            guard let parent = byPID[family.root.parentPID], let key = owner[parent.identity], key != family.familyKey else {
                return family
            }
            return family.linked(toParentFamily: key)
        }
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
            commandHint: commandHint(from: process.commandLine),
            appBundlePrefix: ProcessStaticFacts.appBundlePrefix(of: process.executablePath),
            parentDirectory: ProcessStaticFacts.parentDirectory(of: process.executablePath),
            isHelperNamed: process.name.lowercased().contains("helper"),
            isAppMainBinary: tokens.isAppMainBinary,
            isHardwareEligible: hardwareDetector.isEligibleForGenericHardwareDetection(process),
            duplicateKey: duplicateDetector.candidateKey(for: process, classification: classification)
        )
    }

    private func isAboveHardThreshold(_ process: ProcessMetrics, settings: ThresholdSettings) -> Bool {
        process.memoryForScoringBytes >= settings.memoryBytes || process.cpuPercent >= settings.cpuPercent
    }

    private func root(
        for process: ProcessMetrics,
        byPID: [Int32: ProcessMetrics],
        facts: [Int32: ProcessStaticFacts],
        confidence: [Int32: Double]
    ) -> ProcessMetrics {
        var current = process
        var visited = Set<Int32>()

        while let parent = byPID[current.parentPID], !visited.contains(parent.pid) {
            visited.insert(current.pid)
            guard parent.userID == current.userID else {
                break
            }
            guard shouldClimb(from: current, to: parent, facts: facts, confidence: confidence) else {
                break
            }
            current = parent
        }

        return current
    }

    private func shouldClimb(
        from child: ProcessMetrics,
        to parent: ProcessMetrics,
        facts: [Int32: ProcessStaticFacts],
        confidence: [Int32: Double]
    ) -> Bool {
        let childFacts = facts[child.pid]
        let parentFacts = facts[parent.pid]
        if isOwnWorkload(childFacts), isWorkloadHost(parentFacts) {
            return false
        }
        if confidence[parent.pid, default: 0] >= 0.35 {
            return true
        }
        if sameAppBundle(childFacts, parentFacts) {
            return true
        }
        if parentFacts?.isHelperNamed == true && samePathNeighborhood(childFacts, parentFacts) {
            return true
        }
        return false
    }

    /// Servers, kernels and test or build workers an editor launches are
    /// their own families: a leaking language server must not surface as the
    /// editor, nor make the editor its only stop. Kinds, not sizes, draw the
    /// line, so membership never flips between ticks.
    private func isOwnWorkload(_ facts: ProcessStaticFacts?) -> Bool {
        guard let classification = facts?.classification else { return false }
        return classification.kind.isServiceKind ||
            !classification.traits.isDisjoint(with: [.devServer, .notebookKernel])
    }

    private func isWorkloadHost(_ facts: ProcessStaticFacts?) -> Bool {
        guard let facts else { return false }
        switch facts.classification.kind {
        case .editorApp, .ideService, .electronApp:
            return true
        default:
            return facts.isAppMainBinary
        }
    }

    private func makeFamily(
        root: ProcessMetrics,
        byPID: [Int32: ProcessMetrics],
        children: [Int32: [ProcessMetrics]],
        facts: [Int32: ProcessStaticFacts],
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
            facts: facts,
            confidence: confidence,
            rootIdentities: rootIdentities
        )

        guard !members.isEmpty else {
            return nil
        }

        // Memory carries each member's last-known value; CPU and GPU count
        // only current readings, because a helper cached at 300% during a
        // build would otherwise read as a phantom runaway.
        let coverage = FamilyMeasurementCoverage(members: members, root: root, at: now)
        let resident = members.reduce(UInt64(0)) { $0 + $1.residentMemoryBytes }
        let footprint = members.reduce(UInt64(0)) { $0 + $1.memoryForScoringBytes }
        let cpu = members.reduce(0) { isCurrent($1.cpuMeasurementDate, at: now) ? $0 + $1.cpuPercent : $0 }
        let gpu = members.reduce(0) { isCurrent($1.gpuMeasurementDate, at: now) ? $0 + $1.gpuUsagePercent : $0 }
        let hardwareSignals = hardwareSignals(for: members, profiles: hardwareProfiles)
        let familyConfidence = members.map { confidence[$0.pid, default: 0] }.max() ?? 0
        let familyClassification = familyClassification(root: root, members: members, facts: facts, footprint: footprint, cpu: cpu, now: now)
        let duplicateCluster = bestDuplicateCluster(for: members, clustersByIdentity: duplicateClusterByIdentity)
        let signature = facts[root.pid]?.signature ?? ProcessSignature.from(root: root)
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
            commandHints: commandHints(from: members, facts: facts),
            trend: trend,
            score: score,
            ownedIdentities: owned,
            protectedPIDs: protected,
            signature: signature,
            classification: familyClassification,
            duplicateCluster: duplicateCluster,
            hardwareSignals: hardwareSignals,
            coverage: coverage
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
        facts: [Int32: ProcessStaticFacts],
        confidence: [Int32: Double],
        rootIdentities: Set<ProcessIdentity>
    ) -> [ProcessMetrics] {
        var result: [ProcessMetrics] = []
        var stack = [root]
        var seen = Set<Int32>()
        let rootIsDevFamily = confidence[root.pid, default: 0] >= 0.35
        let rootFacts = facts[root.pid]

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
                let childFacts = facts[child.pid]
                let related = rootIsDevFamily ||
                    confidence[child.pid, default: 0] >= 0.2 ||
                    sameAppBundle(childFacts, rootFacts) ||
                    samePathNeighborhood(childFacts, rootFacts)
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

    private func commandHints(from members: [ProcessMetrics], facts: [Int32: ProcessStaticFacts]) -> [String] {
        var hints: [String] = []
        for process in members {
            guard let hint = facts[process.pid]?.commandHint ?? nil, !hints.contains(hint) else {
                continue
            }
            hints.append(hint)
            if hints.count == 4 {
                break
            }
        }
        return hints
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

    private func sameAppBundle(_ lhs: ProcessStaticFacts?, _ rhs: ProcessStaticFacts?) -> Bool {
        guard let left = lhs?.appBundlePrefix, let right = rhs?.appBundlePrefix else {
            return false
        }
        return left == right
    }

    private func samePathNeighborhood(_ lhs: ProcessStaticFacts?, _ rhs: ProcessStaticFacts?) -> Bool {
        guard let left = lhs?.parentDirectory, !left.isEmpty else { return false }
        return left == rhs?.parentDirectory
    }
}
