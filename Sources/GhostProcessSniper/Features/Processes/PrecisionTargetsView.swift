import SwiftUI
import GhostProcessSniperCore

struct PrecisionTargetsView: View {
    let family: ProcessFamily
    let onPreview: (ProcessIdentity) -> Void

    private var targets: [ProcessMetrics] {
        family.members.sorted {
            if family.totalCPUPercent >= 80, $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            if $0.memoryForScoringBytes != $1.memoryForScoringBytes { return $0.memoryForScoringBytes > $1.memoryForScoringBytes }
            return $0.pid < $1.pid
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Precision targets", systemImage: "scope").font(.headline)
            Text("Inspect the biggest contributors. A single-process preview targets that identity only; the family preview covers the wider tree.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(targets.prefix(3)) { process in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(process.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("PID \(String(process.pid)) · \(RadarFormat.bytes(process.memoryForScoringBytes)) · CPU \(RadarFormat.percent(process.cpuPercent))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Preview this process", systemImage: "scope") { onPreview(process.identity) }
                        .buttonStyle(.bordered)
                        .disabled(!family.ownedIdentities.contains(process.identity) || process.isSystemProcess)
                        .help("Preview PID \(String(process.pid)) and its start time. Nothing stops until you confirm.")
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
        .radarSurface(tint: RadarTheme.brand)
    }
}
