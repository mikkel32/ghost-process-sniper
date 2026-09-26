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
        settings: ThresholdSettings,
        now: Date
    ) -> GhostScore {
        let memoryRatio = Double(footprint) / Double(max(settings.memoryBytes, 1))
        let cpuRatio = cpu / max(settings.cpuPercent, 1)
        let gpuRatio = gpu / 80
        // Only history-proven growth scores as a leak: two close samples can
        // turn one allocation into thousands of MB/min.
        let leakVelocity = trend.credibleMemoryVelocity
        let leakRatio = leakVelocity / max(settings.leakVelocityMegabytesPerMinute, 1)
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
                title: leakRatio >= 1 ? "memory climbing \(Int(leakVelocity.rounded())) MB/min" : "Memory growth",
                detail: String(
                    format: "%.0f MB/min is %.1fx the %.0f MB/min limit",
                    leakVelocity,
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
            reasons.append("memory climbing \(Int(leakVelocity.rounded())) MB/min")
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
            cpuThreshold: settings.cpuPercent,
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
}
