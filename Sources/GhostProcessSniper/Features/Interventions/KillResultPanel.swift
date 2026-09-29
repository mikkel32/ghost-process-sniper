import GhostProcessSniperCore
import SwiftUI

/// A finished stop: the outcome in plain words, one next action when
/// something is left, whether the ports are free, and each process's fate.
struct KillResultPanel: View {
    let report: KillReport
    /// Force-stopping the survivors is offered for a minute after the report.
    let canForceSurvivors: Bool
    let isBusy: Bool
    let forceSurvivors: () -> Void
    /// Looks again at what is still running, for an app that quit after the
    /// wait ended; it never stops anything.
    let checkAgain: () -> Void
    /// Stops what restarted the family, when the advisor found it.
    let stopRestarter: (title: String, action: () -> Void)?
    /// Whether the radar knows the process still holding a port, so it can
    /// be previewed and stopped too.
    let canStopPortHolder: (Int32) -> Bool
    let stopPortHolder: (Int32) -> Void
    /// Whether a process the stop left running is the user's own, and one the
    /// radar still sees, so it can be previewed and stopped too.
    let canStopLeftRunning: (KillTarget) -> Bool
    /// Previews stopping it; only its own confirmation stops it.
    let stopLeftRunning: (KillTarget) -> Void

    var body: some View {
        let narrative = report.narrative
        let rows = KillOutcomeRows.make(report: report)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label(narrative.headline, systemImage: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                if let nextStep = narrative.nextStep {
                    Text(nextStep)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(facts(narrative).enumerated()), id: \.offset) { _, fact in
                    Label(fact, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WrappingHStack(spacing: 6) {
                    ForEach(tags(rows), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
                nextAction(rows)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !report.portOutcomes.isEmpty {
                ports
            }

            if !report.leftRunning.isEmpty {
                leftRunning
            }

            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Outcome by process")
                        .font(.headline)
                    KillTargetRows(rows: rows)
                }
            }
        }
    }

    private var tint: Color {
        report.succeeded ? .green : .orange
    }

    /// The narrative's facts, less the port lines the chips below show and
    /// the left-running line the list below names.
    private func facts(_ narrative: KillOutcomeNarrative) -> [String] {
        let portLines = Set(report.portOutcomes.map(\.text))
        return narrative.details.filter { !portLines.contains($0) && !$0.hasPrefix(KillOutcomeNarrator.leftRunningPrefix) }
    }

    private func tags(_ rows: [KillTarget]) -> [String] {
        let stopped = rows.filter { $0.state == .terminated || $0.state == .forceKilled }.count
        var tags = ["stopped \(stopped)"]
        if !report.forcedPIDs.isEmpty { tags.append("forced \(report.forcedPIDs.count)") }
        if report.realizedMemoryReclaimBytes > 0 { tags.append(RadarFormat.bytes(report.realizedMemoryReclaimBytes)) }
        tags.append(RadarFormat.seconds(report.timeline.totalMilliseconds / 1_000))
        return tags
    }

    @ViewBuilder
    private func nextAction(_ rows: [KillTarget]) -> some View {
        let survivors = rows.filter { $0.state == .survived }.count
        if report.skipForceRequested, survivors > 0 {
            HStack(spacing: 10) {
                Button(role: .destructive, action: forceSurvivors) {
                    Label("Force Stop \(survivors) Process\(survivors == 1 ? "" : "es")", systemImage: "bolt")
                }
                .disabled(!canForceSurvivors || isBusy)
                .help("Sends SIGKILL now to the \(survivors == 1 ? "process" : "\(survivors) processes") still running.")
                checkAgainButton
                if !canForceSurvivors {
                    Text("Open a new preview to force-stop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if survivors > 0 {
            checkAgainButton
        } else if !report.respawnedPIDs.isEmpty, let stopRestarter {
            Button(action: stopRestarter.action) {
                Label(stopRestarter.title, systemImage: "arrow.uturn.up")
            }
            .disabled(isBusy)
        }
    }

    private var checkAgainButton: some View {
        Button(action: checkAgain) {
            Label("Check Again", systemImage: "arrow.clockwise")
        }
        .disabled(isBusy)
        .help("Looks again at what is still running, such as after you answered a save prompt. Nothing is stopped.")
    }

    private var ports: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ports")
                .font(.headline)
            WrappingHStack(spacing: 6) {
                ForEach(report.portOutcomes, id: \.port) { outcome in
                    Label(chipText(outcome), systemImage: chipIcon(outcome))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(chipColor(outcome))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(chipColor(outcome).opacity(0.12), in: Capsule())
                        .help(outcome.text)
                }
            }
            ForEach(report.portOutcomes, id: \.port) { outcome in
                if case .heldBy(_, let pid, _, _) = outcome {
                    HStack(spacing: 8) {
                        Text(outcome.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if canStopPortHolder(pid) {
                            Button("Stop It Too") { stopPortHolder(pid) }
                                .controlSize(.small)
                                .disabled(isBusy)
                        }
                    }
                }
            }
        }
    }

    /// What the stop left running without its parent, each one to stop too.
    private var leftRunning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Left running")
                .font(.headline)
            ForEach(report.leftRunning.prefix(Self.leftRunningRows)) { target in
                HStack(spacing: 8) {
                    Text("\(target.name) (PID \(String(target.pid)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if canStopLeftRunning(target) {
                        Button("Stop It Too") { stopLeftRunning(target) }
                            .controlSize(.small)
                            .disabled(isBusy)
                    }
                }
            }
            if report.leftRunning.count > Self.leftRunningRows {
                Text("and \(report.leftRunning.count - Self.leftRunningRows) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let leftRunningRows = 6

    private func chipText(_ outcome: KillPortOutcome) -> String {
        switch outcome {
        case .freed(let port): "\(port) free"
        case .heldBy(let port, _, let name, _): "\(port) held by \(name)"
        case .unverified(let port): "\(port) likely free"
        }
    }

    private func chipIcon(_ outcome: KillPortOutcome) -> String {
        switch outcome {
        case .freed: "checkmark.circle"
        case .heldBy: "exclamationmark.triangle"
        case .unverified: "questionmark.circle"
        }
    }

    private func chipColor(_ outcome: KillPortOutcome) -> Color {
        switch outcome {
        case .freed: .green
        case .heldBy: .orange
        case .unverified: .secondary
        }
    }
}
