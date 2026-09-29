import GhostProcessSniperCore
import SwiftUI

/// What the user has vouched for, each with what exactly it covers, and Revoke.
struct SentinelTrustedList: View {
    let entries: [SentinelTrustEntry]
    let revoke: (SentinelTrustEntry) -> Void

    var body: some View {
        if !entries.isEmpty {
            RadarSection(title: "Trusted", subtitle: entries.count == 1 ? "1 program" : "\(entries.count) entries",
                         systemImage: "checkmark.shield", accent: .green) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            SentinelProgramIcon(path: entry.path, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.callout.weight(.semibold))
                                Text(entry.scope)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button("Revoke") { revoke(entry) }
                                .controlSize(.small)
                                .help("Sentinel judges \(entry.name) again from its next launch")
                        }
                        .padding(.vertical, 5)
                    }
                    Text("A trusted program that changes (a new signer, a different build, an edited script) is flagged again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }
}
