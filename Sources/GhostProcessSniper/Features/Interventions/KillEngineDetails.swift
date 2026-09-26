import GhostProcessSniperCore
import SwiftUI

/// How the engine reached its plan: scope, strategy, confidence and what the
/// preview cost. Collapsed by default; the plan above says it in plain words.
struct KillEngineDetails: View {
    let preview: KillPreview

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                block(
                    title: "Scope",
                    icon: "person.crop.circle.badge.checkmark",
                    accent: .blue,
                    primary: preview.scopePreview.scope.label,
                    secondary: preview.scopePreview.summary,
                    tags: [
                        "will signal \(preview.scopePreview.targetCount)",
                        "skip \(preview.scopePreview.lockedCount + preview.scopePreview.drift.exitedPIDs.count + preview.scopePreview.drift.recycledPIDs.count)",
                        "nearby \(preview.scopePreview.nearbyCandidates.count)"
                    ],
                    tip: RadarTip(
                        title: "Scope",
                        message: "Exactly which processes will receive signals. Locked (protected or foreign), already-exited, and recycled PIDs are skipped automatically. \"Nearby\" processes look related but are deliberately not targeted."
                    )
                )
                block(
                    title: "Strategy",
                    icon: "dial.low",
                    accent: strategyColor,
                    primary: preview.strategyRecommendation.strategy.label,
                    secondary: preview.strategyForecast.evidenceText,
                    tags: [
                        "\(Int((preview.strategyRecommendation.confidence * 100).rounded()))%",
                        "\(Int((preview.strategyForecast.pClean * 100).rounded()))% clean exit",
                        "\(preview.strategyForecast.observationCount) past stop\(preview.strategyForecast.observationCount == 1 ? "" : "s")",
                        "\(String(format: "%.2f", preview.recommendedGraceSeconds))s grace"
                    ],
                    tip: RadarTip(
                        title: "Strategy",
                        message: "How the stop escalates, chosen per process type: graceful signals first (dev servers get gentler treatment), then verification, and force only for verified survivors. The clean-exit odds come from this process's past stops, starting from similar processes when it has little history."
                    )
                )
            }
            GridRow {
                block(
                    title: "Confidence",
                    icon: "checkmark.shield",
                    accent: KillReadinessStyle.color(preview.readiness),
                    primary: preview.readiness.label,
                    secondary: preview.riskSummary,
                    tags: [
                        "score \(Int(preview.decisionScore.value.rounded()))",
                        preview.watcherAvailable ? "watcher ready" : "watcher off",
                        "\(preview.targets.count) target\(preview.targets.count == 1 ? "" : "s")"
                    ],
                    tip: RadarTip(
                        title: "Confidence",
                        message: "The engine's readiness verdict from a live preflight of the process tree. The Why Stop / Why Wait lists are the actual evidence. Nothing runs until you confirm."
                    )
                )
                block(
                    title: "Budget",
                    icon: "speedometer",
                    accent: preview.performanceReport.didHitBudget ? .orange : .secondary,
                    primary: "\(Int(preview.performanceReport.snapshotMilliseconds.rounded())) ms \(preview.usedCheapSnapshot ? "arena kill graph" : "full preflight")",
                    secondary: "\(preview.arenaStats.processCount) arena rows, \(preview.performanceReport.graphReadCount) PID reads, \(preview.performanceReport.heavyMetricReadCount) target-heavy reads. \(preview.verificationPlanText)",
                    tags: [
                        "arena \(Int(preview.arenaStats.arenaBuildMilliseconds.rounded())) ms",
                        "reuse \(preview.arenaStats.arenaReuseCount)",
                        "reclaim \(RadarFormat.bytes(preview.estimatedMemoryReclaimBytes))",
                        "converted \(preview.targetConversionCount)"
                    ],
                    tip: RadarTip(
                        title: "Budget",
                        message: "What this preview cost to compute. The kill graph is cached and reused between previews, and \"reclaim\" estimates how much memory a successful stop frees."
                    )
                )
            }
        }
    }

    private var strategyColor: Color {
        switch preview.strategyRecommendation.strategy {
        case .standard: .blue
        case .gentleDevServer, .quitApp: .green
        case .carefulShutdown: .purple
        case .stubbornRunaway: .red
        case .inspectOnly: .orange
        }
    }

    private func block(
        title: String,
        icon: String,
        accent: Color,
        primary: String,
        secondary: String,
        tags: [String],
        tip: RadarTip
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                InfoTip(tip: tip)
            }
            Text(primary)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(secondary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(secondary)
            HStack(spacing: 5) {
                ForEach(tags.prefix(4), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.background.opacity(0.45), in: Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum KillReadinessStyle {
    static func color(_ readiness: KillReadiness) -> Color {
        switch readiness {
        case .ready: .green
        case .caution: .orange
        case .locked: .red
        }
    }
}
