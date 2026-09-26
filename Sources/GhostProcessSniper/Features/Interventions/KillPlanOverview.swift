import GhostProcessSniperCore
import SwiftUI

/// The first thing a stop preview shows: in plain words, what will happen,
/// what could go wrong, and what the Mac gets back.
struct KillPlanOverview: View {
    let preview: KillPreview

    private var risk: KillRiskAssessment { preview.riskAssessment }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            plan
            if !risk.hazards.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Before you stop it")
                        .font(.headline)
                    ForEach(risk.hazards) { hazard in
                        KillRiskCard(risk: hazard)
                    }
                }
            }
            gains
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("What will happen")
                    .font(.headline)
                Text(risk.kind.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Text(risk.headline ?? preview.strategyRecommendation.previewText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if preview.strategyProfile.phases.isEmpty {
                Label(preview.strategyRecommendation.reasons.first ?? "Nothing will be stopped.", systemImage: "hand.raised")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preview.strategyProfile.phases) { phase in
                        KillPhaseRow(phase: phase, forceNeedsConfirmation: risk.forceNeedsConfirmation)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadarTheme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var gains: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You get back")
                .font(.headline)
            HStack(spacing: 10) {
                KillGainTile(title: "Memory", value: RadarFormat.bytes(preview.estimatedMemoryReclaimBytes), systemImage: "memorychip")
                KillGainTile(title: "CPU", value: RadarFormat.percent(preview.estimatedCPUReclaimPercent), systemImage: "cpu")
                KillGainTile(title: "Processes", value: "\(preview.targets.count)", systemImage: "square.stack.3d.up")
                if !risk.freedPorts.isEmpty {
                    KillGainTile(title: risk.freedPorts.count == 1 ? "Port" : "Ports",
                                 value: risk.freedPorts.prefix(3).map(String.init).joined(separator: ", "),
                                 systemImage: "network")
                }
            }
            ForEach(risk.benefits.filter { $0.kind != .freesPorts }) { benefit in
                Label(benefit.detail, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct KillPhaseRow: View {
    let phase: KillSignalPhase
    let forceNeedsConfirmation: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: phase.isForce ? "bolt.fill" : "\(phase.order + 1).circle.fill")
                .foregroundStyle(phase.isForce ? Color.red : RadarTheme.brand)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(phase.label)
                .font(.callout)
            Text(phase.signalName)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if phase.isForce, forceNeedsConfirmation { return "only if you allow it" }
        guard phase.waitAfterSeconds >= 0.5 else { return "" }
        return "waits up to \(RadarFormat.seconds(phase.waitAfterSeconds))"
    }
}

struct KillRiskCard: View {
    let risk: KillRisk

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(risk.title)
                    .font(.callout.weight(.semibold))
                Text(risk.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch risk.severity {
        case .danger: .red
        case .caution: .orange
        case .info: .blue
        }
    }

    private var symbol: String {
        switch risk.kind {
        case .unsavedWork: "doc.text"
        case .dataIntegrity: "externaldrive"
        case .stopsContainers: "shippingbox"
        case .lockFile: "lock"
        case .partialInstall: "arrow.down.circle"
        case .interruptedBuild: "hammer"
        case .respawn: "arrow.clockwise"
        case .unloadsModels: "cpu"
        case .freesPorts: "network"
        case .orphaned: "checkmark.circle"
        }
    }
}

private struct KillGainTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
