import GhostProcessSniperCore
import SwiftUI

/// The inspector column beside a family page: quick facts and the first
/// processes of the tree, saying how many more there are.
struct FamilyInspectorView: View {
    let panel: FamilyDetailPanelModel

    private static let treeLimit = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RadarSection(title: "Forensics") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Fresh", panel.forensics.freshnessText)
                        row("CWD", panel.forensics.currentDirectory)
                        row("Files", panel.forensics.openFileText)
                        row("Ports", panel.forensics.portsText)
                    }
                }

                RadarSection(title: "Tree", subtitle: "\(panel.members.count) processes") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(panel.members.prefix(Self.treeLimit)) { process in
                            HStack(spacing: 8) {
                                Text(process.pid == panel.rootPID ? "root" : "child")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .leading)
                                Text(process.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("pid \(String(process.pid))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if panel.members.count > Self.treeLimit {
                            Text("+\(panel.members.count - Self.treeLimit) more on the Processes tab")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}
