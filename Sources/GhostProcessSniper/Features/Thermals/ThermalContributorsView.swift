import GhostProcessSniperCore
import SwiftUI

struct ThermalContributorsView: View {
    let summary: ThermalActivitySummary
    let snapshot: ThermalSnapshot
    let history: ThermalTraceHistory?
    let onInspect: (String) -> Void
    let onBrowse: () -> Void
    let onRefresh: () async -> Void
    @State private var sort: ThermalActivitySort = .activity
    @State private var showAll = false
    @State private var selected: ThermalContributor?
    @State private var isRefreshing = false
    @State private var observations = ThermalObservationWindow()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            // A new sample can redraw between timeline ticks. The scheduled tick
            // date can precede that sample and incorrectly mark it as future data.
            content(at: Date())
        }
        .onChange(of: snapshot, initial: true) { _, current in
            observations.record(current, at: Date())
        }
        .sheet(item: $selected) { selection in
            let current = summary.contributors.first { $0.id == selection.id }
            ThermalContributorDetailView(contributor: current ?? selection,
                isInLatestSample: current != nil, onInspect: onInspect)
        }
    }

    private func content(at now: Date) -> some View {
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot, activity: summary,
            observations: observations, pressure: .current(at: now), at: now)
        let visible = summary.visibleContributors(at: now, sort: sort)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Heat & app activity", systemImage: "thermometer.medium")
                        .font(.title2.weight(.semibold))
                    Text("CPU \(snapshot.temperatureText(snapshot.cpuCelsius, at: now))   /   GPU \(snapshot.temperatureText(snapshot.gpuCelsius, at: now))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    isRefreshing = true
                    Task {
                        await onRefresh()
                        isRefreshing = false
                    }
                } label: {
                    Label(isRefreshing ? "Scanning" : "Scan now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isRefreshing)
                .help("Request a current process and temperature sample.")
            }

            ThermalStatusCard(diagnosis: diagnosis)

            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Apps to review").font(.headline)
                    Spacer(minLength: 12)
                    sortControl.frame(width: 230)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apps to review").font(.headline)
                    sortControl
                }
            }
            Text(diagnosis.nextStep)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if visible.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: diagnosis.isActivityFresh && summary.unavailableProcessCount == 0 ? "leaf" : "clock.badge.exclamationmark")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(emptyMessage(at: now)).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(Array(visible.prefix(showAll ? visible.count : 3))) { contributor in
                        Button { selected = contributor } label: {
                            ThermalContributorRow(contributor: contributor,
                                isLeading: sort == .activity && contributor.id == visible.first?.id, now: now)
                        }
                        .buttonStyle(.plain)
                        .help("Inspect the app's sampled processes and why it appears here. Nothing will be stopped.")
                    }
                }
                if visible.count > 3 {
                    Button(showAll ? "Show top 3" : "Show all \(visible.count) active apps and services") { showAll.toggle() }
                        .font(.callout).buttonStyle(.borderless)
                }
            }

            Divider()
            DisclosureGroup("Temperatures & recent history") {
                ThermalSensorStrip(snapshot: snapshot, history: history, now: now).padding(.top, 10)
                Text(snapshot.unavailableReason ?? "Read-only hardware sensors. No fan or power settings are changed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            .font(.callout.weight(.medium))
            DisclosureGroup("How we assess heat & activity") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature review bands: Warm at 70°C, Hot at 80°C, Very hot at 90°C. These are app review thresholds, not Apple operating limits or a hardware-fault diagnosis.")
                    Text("Trend uses at least 4 distinct readings across 30 seconds. It compares early and recent readings from the same sensor. Gaps break the history; a timer tick never counts as a new measurement. Recent history is collected while this dashboard is open.")
                    Text("App helpers are grouped under their enclosing application. The list is ranked by observed CPU/GPU activity, not by measured heat contribution.")
                    Text("CPU capacity compares CPU time with all available logical processors. GPU activity is reported process activity; zero can also mean no GPU activity was reported. Neither is a percentage of heat.")
                    Text("Missing, invalid, future-dated and expired readings are excluded. Hardware temperature alone cannot identify the responsible app.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            .font(.callout.weight(.medium))
            HStack(alignment: .top, spacing: 12) {
                Text(diagnosis.coverageText)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Process list", action: onBrowse).font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(20)
        .radarSurface(tint: RadarTheme.brand, cornerRadius: 18)
    }

    private var sortControl: some View {
        Picker("Rank activity by", selection: $sort) {
            ForEach(ThermalActivitySort.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityLabel("Rank app activity by")
    }

    private func emptyMessage(at now: Date) -> String {
        if summary.sampledAt == .distantPast { return "Waiting for the first process sample." }
        if now.timeIntervalSince(summary.sampledAt) > ThermalActivitySummary.maximumAge || !summary.contributors.isEmpty {
            return "Waiting for updated app activity"
        }
        if summary.observedProcessCount == 0 || summary.unavailableProcessCount == summary.observedProcessCount {
            return "No usable process readings yet"
        }
        if summary.unavailableProcessCount > 0 { return "Still measuring app activity" }
        return "No strongly active app in the current sample"
    }
}
