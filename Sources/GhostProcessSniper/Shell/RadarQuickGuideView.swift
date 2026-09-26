import SwiftUI

struct RadarQuickGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A clearer picture of your Mac")
                        .font(.title.weight(.bold))
                    Text("Start with the overview. Investigate only what needs attention.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close quick guide")
                .keyboardShortcut(.cancelAction)
            }

            guideStep("1", title: "See the whole picture", detail: "The overview separates urgent issues from early warnings. Summary cards open the corresponding processes or tools.", icon: "square.grid.2x2")
            guideStep("2", title: "Find the process behind the numbers", detail: "All Processes shows every tracked family. Search by name, command, or path; sort by memory, CPU, or priority.", icon: "list.bullet.rectangle")
            guideStep("3", title: "Review before you act", detail: "Open a family to inspect its process tree and history. A stop preview shows the exact targets before you confirm anything.", icon: "checkmark.shield")

            Divider()
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    shortcut("Find processes", keys: "⌘F")
                    shortcut("Scan now", keys: "⌘R")
                    shortcut("Overview", keys: "⌘1")
                }
                VStack(alignment: .leading, spacing: 12) {
                    shortcut("Next / previous family", keys: "⌘↓ / ⌘↑")
                    shortcut("Toggle inspector", keys: "⌥⌘I")
                    shortcut("Settings", keys: "⌘,")
                }
            }
            Text("Celsius readings are hardware temperatures, not per-process scores. Action labels explain urgency. Use Precision targets to preview one process; the family preview covers the wider tree. Previews expire after 60 seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Got it") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(30)
        .frame(width: 600)
        .tint(RadarTheme.brand)
    }

    private func guideStep(_ number: String, title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(RadarTheme.brand)
                .frame(width: 42, height: 42)
                .background(RadarTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(number + ". " + title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(keys).fontWeight(.medium)
        }
        .font(.callout)
    }
}
