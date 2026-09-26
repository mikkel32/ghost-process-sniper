import GhostProcessSniperCore
import SwiftUI

struct ThermalContributorDetailView: View {
    let contributor: ThermalContributor
    let isInLatestSample: Bool
    let onInspect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var processSort: ThermalActivitySort = .cpu

    private func isCurrent(_ date: Date?, at now: Date) -> Bool {
        guard let date else { return false }
        return (0...ThermalActivitySummary.maximumAge).contains(now.timeIntervalSince(date))
    }

    private func orderedProcesses(at now: Date) -> [ThermalProcessEvidence] {
        switch processSort {
        case .activity: contributor.processes
        case .cpu: contributor.processes.sorted {
            let left = isCurrent($0.cpuMeasuredAt, at: now) ? $0.cpuPercent : -1
            let right = isCurrent($1.cpuMeasuredAt, at: now) ? $1.cpuPercent : -1
            return left == right ? $0.identity.pid < $1.identity.pid : left > right
        }
        case .gpu: contributor.processes.sorted {
            let left = isCurrent($0.gpuMeasuredAt, at: now) ? $0.gpuPercent : -1
            let right = isCurrent($1.gpuMeasuredAt, at: now) ? $1.gpuPercent : -1
            return left == right ? $0.identity.pid < $1.identity.pid : left > right
        }
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            let now = Date()
            let fresh = isInLatestSample && (0...ThermalActivitySummary.maximumAge)
                .contains(now.timeIntervalSince(contributor.measuredAt))
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ThermalAppIcon(path: contributor.applicationPath, isSystemProcess: contributor.isSystemProcess)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contributor.displayName).font(.title2.weight(.semibold))
                        Text(fresh ? "Measured \(contributor.measuredAt.formatted(date: .omitted, time: .standard))" : "Outdated activity snapshot")
                            .font(.caption).foregroundStyle(fresh ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !fresh {
                            Label("This app has left the active sample or its readings have expired. Return to the dashboard and scan again.", systemImage: "clock.badge.exclamationmark")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Why this app appears").font(.headline)
                            Text(contributor.workloadExplanation)
                                .font(.callout).foregroundStyle(.secondary)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { metricTiles(at: now) }
                                VStack(spacing: 8) { metricTiles(at: now) }
                            }
                            Text("At this scan, CPU was measured for \(contributor.cpuMeasuredProcessCount) of \(contributor.processCount) processes; GPU was reported for \(contributor.gpuMeasuredProcessCount) of \(contributor.processCount).")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("These readings show resource use at one point in time. They do not measure the degrees or watts this app added to your Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Processes doing the work").font(.headline)
                                Spacer(minLength: 8)
                                Picker("Rank processes by", selection: $processSort) {
                                    ForEach(ThermalActivitySort.allCases) { value in
                                        Text(value.rawValue).tag(value)
                                    }
                                }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                                .accessibilityLabel("Rank sampled processes by")
                            }
                            Text("Process CPU uses 100% for one fully used logical core, so values can exceed 100%.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(orderedProcesses(at: now)) { process in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(process.name).font(.callout.weight(.medium)).lineLimit(2)
                                        Text("PID \(String(process.identity.pid))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(!isCurrent(process.cpuMeasuredAt, at: now) ? "CPU unavailable" :
                                             "CPU \(ThermalActivityFormat.percent(process.cpuPercent))")
                                            .fontWeight(.semibold)
                                        Text(!isCurrent(process.gpuMeasuredAt, at: now) ? "GPU unreported" :
                                             "Reported GPU \(ThermalActivityFormat.percent(process.gpuPercent))")
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption.monospacedDigit())
                                }
                                .padding(12)
                                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if contributor.processCount > contributor.processes.count {
                                Text("Showing \(contributor.processes.count) of \(contributor.processCount) sampled processes.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("A reported GPU zero does not rule out graphics work elsewhere. Missing CPU or GPU readings are shown as unavailable.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What to try").font(.headline)
                            Text(contributor.suggestedAction).font(.callout).foregroundStyle(.secondary)
                            if !contributor.canInspectFamily {
                                Text("This app is outside the current process-family filter. Its sampled processes are still visible above.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if contributor.canInspectFamily {
                    Button("Open process inspector", systemImage: "sidebar.right") {
                        dismiss()
                        onInspect(contributor.familyKey)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!fresh)
                    .help("Open the observed process family. Nothing is stopped.")
                }
            }
            .padding(24)
        }
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 700, minHeight: 460, idealHeight: 620, maxHeight: 800)
    }

    @ViewBuilder
    private func metricTiles(at now: Date) -> some View {
        ThermalDetailMetric(title: "CPU", value: !isCurrent(contributor.cpuMeasuredAt, at: now) ? "Unavailable" :
            ThermalActivityFormat.percent(contributor.cpuPercent),
            detail: "100% = one core", tint: RadarTheme.brand)
        ThermalDetailMetric(title: "All CPU capacity", value: !isCurrent(contributor.cpuMeasuredAt, at: now) ? "Unavailable" :
            ThermalActivityFormat.percent(contributor.cpuCapacityPercent),
            detail: "Across all logical cores", tint: RadarTheme.brand)
        ThermalDetailMetric(title: "Reported GPU", value: !isCurrent(contributor.gpuMeasuredAt, at: now) ? "Unreported" :
            ThermalActivityFormat.percent(contributor.gpuPercent),
            detail: "Process activity", tint: RadarTheme.brandSecondary)
    }
}

private struct ThermalDetailMetric: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
