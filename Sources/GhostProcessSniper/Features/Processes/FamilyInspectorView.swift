import GhostProcessSniperCore
import SwiftUI

/// The inspector column beside a family page: quick facts and the biggest
/// processes of the tree, saying how many more there are.
struct FamilyInspectorView: View {
    let panel: FamilyDetailPanelModel
    /// The family's live forensics date; the panel's own text can be stale.
    let forensicsFreshness: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RadarSection(title: "Forensics") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Fresh", FamilyForensicsSummary.freshnessText(forensicsFreshness))
                        row("CWD", panel.forensics.currentDirectory)
                        row("Files", panel.forensics.openFileText)
                        row("Ports", panel.forensics.portsText)
                    }
                }

                RadarSection(title: "Tree", subtitle: "\(panel.members.count) processes, by memory") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(panel.inspectorTree) { process in
                            HStack(spacing: 6) {
                                Text(process.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                if process.isRoot {
                                    FamilyMemberTag(text: "root")
                                }
                                Spacer()
                                Text(process.memoryText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if panel.members.count > panel.inspectorTree.count {
                            Text("+\(panel.members.count - panel.inspectorTree.count) more on the Processes tab")
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
