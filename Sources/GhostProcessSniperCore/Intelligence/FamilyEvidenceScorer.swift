import Foundation

/// Turns a family's measured footprint, CPU, GPU, trend and host-wide
/// offender signals into the additive evidence score and initial Heat.
struct FamilyEvidenceScorer: Sendable {
    func score(
        root: ProcessMetrics,
        members: [ProcessMetrics],
        footprint: UInt64,
        cpu: Double,
        gpu: Double,
        confidence: Double,
        duplicateCluster: DuplicateProcessCluster?,
        hardwareSignals: [HardwareOffenderSignal],
        trend: TrendMetrics,
        forgotten: ForgottenAssessment,
        zombieChildCount: Int,
        cpuBehavior: CPUBehavior = .none,
        cpuLimit: Double? = nil,
        isOneShotBuild: Bool = false,
        settings: ThresholdSettings,
        now: Date
    ) -> GhostScore {
        let memoryRatio = Double(footprint) / Double(max(settings.memoryBytes, 1))
        let cpuLimit = max(cpuLimit ?? settings.cpuPercent, 1)
        let cpuRatio = cpu / cpuLimit
        let gpuRatio = gpu / 80
        // Only history-proven growth scores as a leak: two close samples can
        // turn one allocation into thousands of MB/min.
        let leakVelocity = trend.credibleMemoryVelocity
        let leakRatio = leakVelocity / max(settings.leakVelocityMegabytesPerMinute, 1)
        let childFanout = max(0, members.count - 6)
        // Only copies started independently count; a worker pool inside one
        // family is how the tool works, not a duplicate. And only ones whose
        // stopping gives something back: idle 2 MB leftovers stay listed on
        // the Duplicates page but are not evidence about any family.
        let copies = duplicateCluster.flatMap { $0.countsAsIndependentCopies && $0.copiesMatter ? $0 : nil }
        let duplicateImpact = copies.map { min(12, Double($0.independentRootCount - 1) * 4) } ?? 0
        let hardwareImpact = min(24, hardwareSignals.reduce(0) { $0 + $1.impact })
        let ageMinutes = max(0, now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(root.identity.startTimeSeconds))) / 60)
        let forgottenImpact = confidence >= 0.35 && forgotten.likelihood >= 0.45 ? min(8, forgotten.likelihood * 8) : 0

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
                slot: "memory",
                kind: .memory,
                title: memoryRatio >= 1 ? "memory above threshold" : "Memory footprint",
                detail: "\(RadarFormat.bytes(footprint)) is \(RadarFormat.fixed1(memoryRatio))x the \(RadarFormat.bytes(settings.memoryBytes)) limit",
                impact: memoryImpact,
                level: componentLevel(memoryRatio),
                ratio: memoryRatio
            ),
            GhostScoreComponent(
                slot: "cpu",
                kind: .cpu,
                title: cpuRatio >= 1 ? "CPU above threshold" : "CPU activity",
                detail: "\(RadarFormat.fixed0(cpu))% is \(RadarFormat.fixed1(cpuRatio))x the \(RadarFormat.fixed0(cpuLimit))% limit",
                impact: cpuImpact,
                level: componentLevel(cpuRatio, critical: 1.15),
                ratio: cpuRatio
            ),
            GhostScoreComponent(
                slot: "gpu",
                kind: .gpu,
                title: gpuRatio >= 1 ? "GPU above threshold" : "GPU activity",
                detail: "\(RadarFormat.fixed0(gpu))% GPU utilization",
                impact: gpuImpact,
                level: componentLevel(gpuRatio, hot: 0.55, critical: 1),
                ratio: gpuRatio
            ),
            GhostScoreComponent(
                slot: "leak",
                kind: .leak,
                title: leakRatio >= 1 ? "memory climbing \(Int(leakVelocity.rounded())) MB/min" : "Memory growth",
                detail: "\(RadarFormat.fixed0(leakVelocity)) MB/min is \(RadarFormat.fixed1(leakRatio))x the " +
                    "\(RadarFormat.fixed0(settings.leakVelocityMegabytesPerMinute)) MB/min limit",
                impact: leakImpact,
                // A launch allocates fast while it warms up, any app can for a few
                // seconds, and a build takes memory it gives back when it ends: the
                // climb is shown, but it is not a leak (Leaks, "Sustained memory
                // growth", a culprit) until grace is over and a minute of it is seen.
                level: StartupGrace.isStarting(root: root, now: now) || !trend.growthIsSustained || isOneShotBuild
                    ? min(componentLevel(leakRatio, critical: 1.6), .watch)
                    : componentLevel(leakRatio, critical: 1.6),
                ratio: leakRatio
            ),
            GhostScoreComponent(
                slot: "relevance",
                kind: .background,
                title: "Process relevance",
                detail: "\(Int((confidence * 100).rounded()))% confidence this belongs to the selected radar scope",
                impact: confidenceImpact,
                level: confidence >= 0.65 ? .watch : .quiet
            )
        ]

        if fanoutImpact > 0 {
            components.append(GhostScoreComponent(
                slot: "fanout",
                kind: .fanout,
                title: "\(members.count - 1) child processes",
                detail: "Large process trees consume more resources and are harder to leave behind cleanly",
                impact: fanoutImpact,
                level: childFanout >= 6 ? .hot : .watch
            ))
        }
        if let copies, duplicateImpact > 0 {
            components.append(GhostScoreComponent(
                slot: "duplicate",
                kind: .fanout,
                title: "\(copies.independentRootCount) independent copies",
                detail: copies.reason,
                impact: duplicateImpact,
                level: copies.independentRootCount >= 4 ? .hot : .watch
            ))
        }
        if forgottenImpact > 0 {
            components.append(GhostScoreComponent(
                slot: "forgotten",
                kind: .background,
                title: "likely forgotten",
                detail: forgotten.facts.isEmpty ? "Nothing suggests anyone is using it" : sentence(forgotten.facts.joined(separator: ", ")),
                impact: forgottenImpact,
                level: .watch
            ))
        }
        if zombieChildCount >= 3 {
            components.append(GhostScoreComponent(
                slot: "zombies",
                kind: .system,
                title: "\(zombieChildCount) unreaped child processes",
                detail: "The parent never collected its exited children; only restarting the parent clears them",
                impact: 4,
                level: .watch
            ))
        }
        if ageImpact > 0 {
            components.append(GhostScoreComponent(
                slot: "age",
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
            var signalIndex: [HardwareOffenderSignalKind: Int] = [:]
            components.append(contentsOf: hardwareSignals.map { signal in
                let index = signalIndex[signal.kind, default: 0]
                signalIndex[signal.kind] = index + 1
                let kind: GhostScoreComponentKind = switch signal.kind {
                case .memoryPressure: .memory
                case .cpuPressure: .cpu
                case .gpuPressure: .gpu
                case .threadPressure, .sampleOutlier: .system
                }
                return GhostScoreComponent(
                    slot: "hardware.\(signal.kind.rawValue).\(index)",
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
            reasons.append("memory climbing \(Int(leakVelocity.rounded())) MB/min")
        }
        for signal in hardwareSignals.prefix(3) where !reasons.contains(signal.reason) {
            reasons.append(signal.reason)
        }
        if childFanout > 0 {
            reasons.append("\(members.count - 1) child processes")
        }
        if let copies {
            reasons.append("\(copies.independentRootCount) independent copies")
        }
        if forgottenImpact > 0 {
            reasons.append("likely forgotten")
        }
        if zombieChildCount >= 3 {
            reasons.append("\(zombieChildCount) zombie children")
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
            cpuThreshold: cpuLimit,
            gpuRatio: gpuRatio,
            leakRatio: leakRatio,
            trend: trend,
            hardwareLevel: hardwareLevel,
            cpuBehavior: cpuBehavior,
            isStarting: StartupGrace.isStarting(root: root, now: now),
            isOneShotBuild: isOneShotBuild
        )
        if let copies, heat.level == .quiet {
            heat = GhostHeat(
                value: max(30, heat.value),
                level: .watch,
                confidence: max(0.5, heat.confidence),
                evidence: heat.evidence + ["\(copies.independentRootCount) independent copies need review"],
                sustainedSignalCount: heat.sustainedSignalCount,
                corroborationCount: heat.corroborationCount
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

    private func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
