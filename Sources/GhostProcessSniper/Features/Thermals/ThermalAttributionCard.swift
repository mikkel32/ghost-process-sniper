import GhostProcessSniperCore
import SwiftUI

/// Shows the measured workload separately from the hardware temperature.
struct ThermalAttributionCard: View {
    let summary: ThermalActivitySummary
    let diagnosis: ThermalDiagnosis
    let insight: ThermalAppInsight
    let now: Date
    /// Offered only for a repeated, user-owned heat suspect; it opens the stop preview.
    let stopTarget: ThermalStopTarget?
    let onInspect: (ThermalContributor) -> Void
    let onStop: (QuickStopAction) -> Void
    let onCompare: (ThermalContributor) -> Void
    let onBrowse: () -> Void
    let onRefresh: () -> Void

    private var isFresh: Bool { diagnosis.isActivityFresh }

    private var cpuLeader: ThermalContributor? {
        guard isFresh else { return nil }
        return summary.visibleContributors(at: now, sort: .cpu).first {
            $0.cpuCapacityPercent(at: now) != nil && $0.cpuPercent >= 5
        }
    }

    private var gpuLeader: ThermalContributor? {
        guard isFresh else { return nil }
        return summary.visibleContributors(at: now, sort: .gpu).first {
            $0.gpuActivityPercent(at: now) != nil && $0.gpuPercent >= 5
        }
    }

    private var earlierWork: ThermalRecentContributor? {
        isFresh ? summary.earlierContributor(at: now) : nil
    }

    private var scopeTitle: String {
        if !isFresh { return "Outdated scan" }
        if summary.observedProcessCount == 0 { return "No process data yet" }
        return summary.cpuObservedProcessCount < summary.observedProcessCount ||
            summary.gpuObservedProcessCount < summary.observedProcessCount ? "Partial resource readings" : "Process scan"
    }

    private var scopeDetail: String {
        guard isFresh else { return "Scan again before using app activity to explain current heat." }
        guard summary.observedProcessCount > 0 else { return "No process readings yet." }
        return "At the scan, of \(summary.observedProcessCount) processes seen, CPU was measured for \(summary.cpuObservedProcessCount) and GPU was reported for \(summary.gpuObservedProcessCount)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    badge.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    if isFresh { sampleAge.fixedSize(horizontal: true, vertical: false) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    badge
                    if isFresh { sampleAge }
                }
            }

            Text(insight.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(interpretation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isFresh {
                AdaptivePairLayout(breakpoint: 460, spacing: 8) {
                    resourceCards
                }
            }

            if let earlierWork {
                earlierWorkCard(earlierWork)
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: isFresh && summary.cpuObservedProcessCount == summary.observedProcessCount &&
                      summary.gpuObservedProcessCount == summary.observedProcessCount
                      ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(RadarTheme.brand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeTitle).font(.caption.weight(.semibold))
                    Text(scopeDetail).font(.caption).foregroundStyle(.secondary)
                    if isFresh {
                        Text(summary.historySampleCount > 1
                             ? "Observation window: \(summary.historySampleCount) scans across \(Int(summary.historySpanSeconds))s"
                             : "Observation window: no repeated scans yet")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.5)
            Text(insight.action)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let contributor = insight.contributor, isFresh {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions(contributor) }
                    VStack(alignment: .leading, spacing: 8) { actions(contributor) }
                }
            } else if isFresh {
                Button("Explore all processes", systemImage: "list.bullet.rectangle", action: onBrowse)
                    .buttonStyle(.bordered)
            } else {
                Button("Scan app activity", systemImage: "arrow.clockwise", action: onRefresh)
                    .buttonStyle(.borderedProminent).tint(RadarTheme.brand)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RadarTheme.brand.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(RadarTheme.brand.opacity(0.17), lineWidth: 1) }
    }

    private var interpretation: String { insight.evidence }

    private var badge: some View {
        Text(insight.badge.uppercased())
            .font(.caption.weight(.semibold)).tracking(0.8)
            .foregroundStyle(RadarTheme.brand)
    }

    private var sampleAge: some View {
        Text(summary.sampledAt, style: .relative)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("Age of the latest process scan")
    }

    @ViewBuilder
    private var resourceCards: some View {
        ThermalResourceLeader(title: "CPU", symbol: "cpu", resource: .cpu, contributor: cpuLeader,
            amount: cpuLeader.map { ThermalActivityFormat.percent($0.cpuPercent) },
            explanation: cpuLeader.map { "\(ThermalActivityFormat.percent($0.cpuCapacityPercent)) of all CPU capacity" }
                ?? (summary.cpuObservedProcessCount == 0 ? "CPU readings unavailable" : "No current notable CPU reading"),
            emptyDetail: "One logical core equals 100% CPU", tint: RadarTheme.brand, now: now, onInspect: onInspect)
        ThermalResourceLeader(title: "Graphics", symbol: "square.3.layers.3d", resource: .gpu, contributor: gpuLeader,
            amount: gpuLeader.map { ThermalActivityFormat.percent($0.gpuPercent) },
            explanation: gpuLeader == nil
                ? (summary.gpuObservedProcessCount == 0 ? "GPU activity unreported" : "No current notable GPU reading")
                : "Reported GPU activity",
            emptyDetail: "Zero reported is not proof of no GPU work", tint: RadarTheme.brandSecondary,
            now: now, onInspect: onInspect)
    }

    private func earlierWorkCard(_ work: ThermalRecentContributor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("EARLIER IN THE LAST 3 MINUTES", systemImage: "clock.arrow.circlepath")
                .font(.caption2.weight(.semibold)).tracking(0.4)
                .foregroundStyle(.orange)
            HStack(alignment: .firstTextBaseline) {
                Text(work.displayName).font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(work.lastActiveAt, style: .relative)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(peakSummary(for: work))
                .font(.caption).foregroundStyle(.secondary)
            Text(work.activeSampleCount >= 2
                ? "Seen in \(work.activeSampleCount) scans spanning \(Int(work.activeSpanSeconds))s. Earlier work may still matter while a sensor cools."
                : "Seen in one scan. This may have been a brief spike; the heat cause is unconfirmed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.14), lineWidth: 1) }
    }

    private func peakSummary(for work: ThermalRecentContributor) -> String {
        var values: [String] = []
        if work.peakCPUCapacityPercent > 0 {
            values.append("CPU peak: \(ThermalActivityFormat.percent(work.peakCPUCapacityPercent)) of all cores")
        }
        if work.peakGPUPercent > 0 {
            values.append("reported GPU peak: \(ThermalActivityFormat.percent(work.peakGPUPercent))")
        }
        return values.joined(separator: "; ")
    }

    @ViewBuilder
    private func actions(_ contributor: ThermalContributor) -> some View {
        Button("Inspect \(contributor.displayName)", systemImage: "magnifyingglass") {
            onInspect(contributor)
        }
        .buttonStyle(.borderedProminent).tint(RadarTheme.brand)
        if let stopTarget {
            ThermalStopButton(target: stopTarget, onStop: onStop)
        }
        Button("Compare after a change", systemImage: "arrow.left.arrow.right") {
            onCompare(contributor)
        }
        .buttonStyle(.bordered)
        .help("Save this reading, change optional work yourself, then compare new measurements. Nothing is paused automatically.")
    }
}

private struct ThermalResourceLeader: View {
    let title: String
    let symbol: String
    let resource: ThermalActivitySort
    let contributor: ThermalContributor?
    let amount: String?
    let explanation: String
    let emptyDetail: String
    let tint: Color
    let now: Date
    let onInspect: (ThermalContributor) -> Void

    private var topProcess: ThermalProcessEvidence? {
        guard let contributor else { return nil }
        return contributor.processes.filter { process in
            let measuredAt = resource == .cpu ? process.cpuMeasuredAt : process.gpuMeasuredAt
            guard let measuredAt else { return false }
            return (0...ThermalActivitySummary.maximumAge).contains(now.timeIntervalSince(measuredAt))
        }.max {
            resource == .cpu ? $0.cpuPercent < $1.cpuPercent : $0.gpuPercent < $1.gpuPercent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            if let contributor, let amount {
                Button { onInspect(contributor) } label: {
                    HStack(spacing: 7) {
                        ThermalAppIcon(path: contributor.applicationPath,
                            isSystemProcess: contributor.isSystemProcess)
                        Text(contributor.displayName)
                            .font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Inspect this app's sampled processes")
                Text(amount).font(.title3.monospacedDigit().weight(.semibold))
                Text(explanation).font(.caption2).foregroundStyle(.secondary)
                if let process = topProcess {
                    Text("Top sampled process: \(process.name)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(explanation).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(emptyDetail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 102, alignment: .topLeading)
        .padding(12)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.12), lineWidth: 1) }
    }
}
