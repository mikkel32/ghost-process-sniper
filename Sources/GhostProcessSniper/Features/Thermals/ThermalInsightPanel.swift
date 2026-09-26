import GhostProcessSniperCore
import SwiftUI

/// Temperature, a named workload, and its next step share one panel. On the
/// Overview it sits below the queues and metrics, and moves up to second,
/// under the verdict, only while the Mac is throttling or has stayed very
/// hot (OverviewThermalBandTracker).
struct ThermalInsightPanel: View {
    let summary: ThermalActivitySummary
    let snapshot: ThermalSnapshot
    let observations: ThermalObservationWindow
    /// Resolves the family a stop would target; nil when stopping is not offered.
    let stopTarget: (ThermalContributor) -> ThermalStopTarget?
    let onInspect: (String) -> Void
    let onStop: (QuickStopAction) -> Void
    let onBrowse: () -> Void
    let onRefresh: () async -> Void
    @State private var sort: ThermalActivitySort = .activity
    @State private var expanded = false
    @State private var showEvidence = false
    @State private var refreshing = false
    @State private var selected: ThermalContributor?
    @State private var coolingCheck: ThermalCoolingCheck?

    var body: some View {
        TimelineView(.explicit(ThermalExpirySchedule.dates(summary.expiryDates(after: .now) + [snapshot.expiresAt]))) { _ in
            let now = Date()
            let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot, activity: summary,
                observations: observations, pressure: .current(at: now), at: now)
            let insight = ThermalAppInsight.evaluate(activity: summary, diagnosis: diagnosis, at: now)
            let rows = summary.visibleContributors(at: now, sort: sort)
            VStack(alignment: .leading, spacing: 18) {
                header(diagnosis: diagnosis)
                AdaptivePairLayout(breakpoint: 760, spacing: 14) {
                    ThermalTemperatureHero(diagnosis: diagnosis, snapshot: snapshot, observations: observations, now: now)
                    ThermalAttributionCard(summary: summary, diagnosis: diagnosis, insight: insight, now: now,
                        stopTarget: insight.stopCandidate(diagnosis: diagnosis).flatMap(stopTarget),
                        onInspect: { selected = $0 },
                        onStop: onStop,
                        onCompare: { coolingCheck = ThermalCoolingCheck(contributor: $0, snapshot: snapshot, at: now) },
                        onBrowse: onBrowse,
                        onRefresh: { Task { await refresh() } })
                }
                if let coolingCheck {
                    comparisonCard(coolingCheck.evaluate(activity: summary, snapshot: snapshot, at: now))
                }
                activityHeader
                if rows.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path").foregroundStyle(.secondary)
                        Text(insight.kind == .recent
                            ? "Current activity is quieter. The recent workload above may still be relevant."
                            : diagnosis.isActivityFresh ? "No active contributors in the available readings."
                            : "App readings will appear after a fresh scan.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("All processes", action: onBrowse).buttonStyle(.bordered)
                    }
                    .padding(14)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(rows.prefix(expanded ? 12 : 3))) { contributor in
                            Button { selected = contributor } label: {
                                ThermalContributorRow(contributor: contributor,
                                    isLeading: contributor.id == rows.first?.id, now: now)
                            }
                            .buttonStyle(.plain)
                            .help("Review the measured workload and its sampled processes.")
                        }
                    }
                    if rows.count > 3 {
                        Button(expanded ? "Show fewer apps" : "Show more apps & services (\(rows.count))",
                               systemImage: expanded ? "chevron.up" : "chevron.down") { expanded.toggle() }
                            .font(.caption.weight(.medium)).buttonStyle(.plain).foregroundStyle(RadarTheme.brand)
                    }
                    if expanded && rows.count > 12 {
                        Button("Explore remaining processes", action: onBrowse).font(.caption)
                    }
                }
                Divider().opacity(0.5)
                DisclosureGroup("Temperature history & measurement details", isExpanded: $showEvidence) {
                    VStack(alignment: .leading, spacing: 12) {
                        ThermalSensorStrip(snapshot: snapshot, observations: observations, now: now)
                        Text(diagnosis.explanation).font(.callout)
                        Text(diagnosis.coverageText)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                }
                .font(.caption.weight(.medium))
                HStack {
                    Spacer(minLength: 8)
                    Button("All processes", action: onBrowse).font(.caption).buttonStyle(.plain)
                }
            }
            .padding(20)
            .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
        }
        .sheet(item: $selected) { contributor in
            let current = summary.visibleContributors(at: Date()).first { $0.id == contributor.id }
            ThermalContributorDetailView(contributor: current ?? contributor,
                isInLatestSample: current != nil,
                stopTarget: current.flatMap(stopTarget),
                onInspect: onInspect, onStop: onStop)
        }
    }

    private func header(diagnosis: ThermalDiagnosis) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                headerTitle
                Spacer(minLength: 8)
                scanStatus(diagnosis: diagnosis)
                scanButton
            }
            VStack(alignment: .leading, spacing: 10) {
                headerTitle
                HStack(spacing: 12) {
                    scanStatus(diagnosis: diagnosis)
                    Spacer(minLength: 8)
                    scanButton
                }
            }
        }
    }

    private var headerTitle: some View {
        HStack(spacing: 6) {
            Label("Heat & CPU activity", systemImage: "thermometer.medium")
                .font(.title3.weight(.semibold))
            InfoTip(tip: readingTip)
        }
    }

    /// The fixed caveats live in one place instead of under every card.
    private var readingTip: RadarTip {
        RadarTip(title: "How to read these numbers", message: "Warm, Hot and Very hot are review bands starting at 70, 80 and 90 °C, not hardware limits. CPU 100% is one fully used logical core; CPU capacity combines all of them. GPU values are reported activity, and zero is not proof of no GPU work. App activity is a clue to the workload, not a measured share of heat or watts, and other work may be missing from a scan.")
    }

    private func scanStatus(diagnosis: ThermalDiagnosis) -> some View {
        Label(diagnosis.isActivityFresh ? "Recent scan" : "Needs a scan",
              systemImage: diagnosis.isActivityFresh ? "circle.fill" : "clock")
            .font(.caption).foregroundStyle(diagnosis.isActivityFresh ? RadarTheme.brand : .secondary)
    }

    private var scanButton: some View {
        Button(refreshing ? "Scanning..." : "Scan now", systemImage: "arrow.clockwise") {
            Task { await refresh() }
        }
        .buttonStyle(.bordered).disabled(refreshing)
        .accessibilityLabel(refreshing ? "Scanning app activity" : "Scan heat and app activity now")
    }

    private var activityHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Measured app activity").font(.headline)
                Spacer(minLength: 12)
                sortPicker
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Measured app activity").font(.headline)
                sortPicker
            }
        }
    }

    private var sortPicker: some View {
        Picker("Rank activity by", selection: $sort) {
            ForEach(ThermalActivitySort.allCases) { value in Text(value.rawValue).tag(value) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 230)
        .accessibilityLabel("Rank app activity by")
        .help("Combined ranks by the strongest resource signal in the scan, not by measured heat.")
    }

    private func comparisonCard(_ result: ThermalCoolingCheck.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(result.title, systemImage: "arrow.left.arrow.right").font(.callout.weight(.semibold))
                Spacer()
                Button("Dismiss comparison", systemImage: "xmark") { coolingCheck = nil }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
            }
            Text(result.detail).font(.callout)
            Text(result.note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RadarTheme.brand.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await onRefresh()
    }
}

/// Readings expire at known instants, so thermal views re-render then instead of on a
/// fixed timer; monitor publishes cover everything else. The margin lands each render
/// just past a closed validity boundary.
enum ThermalExpirySchedule {
    static func dates(_ dates: [Date], after now: Date = Date()) -> [Date] {
        Set(dates.filter { $0 > now }).sorted().map { $0.addingTimeInterval(0.05) }
    }
}
