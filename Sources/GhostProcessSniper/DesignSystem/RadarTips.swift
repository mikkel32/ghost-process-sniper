import SwiftUI

/// A rich hover explanation for a feature: what it shows, how to read it,
/// and any shortcut. Rendered by `InfoTip` as a popover on hover.
struct RadarTip {
    let title: String
    let message: String
    var shortcut: String?
}

/// A small ⓘ that opens a styled popover on hover — faster and richer than
/// the system tooltip, and discoverable.
struct InfoTip: View {
    let tip: RadarTip

    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(isPresented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
            .buttonStyle(.plain)
            .contentShape(Circle().inset(by: -4))
            .onHover { hovering in
                hoverTask?.cancel()
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: hovering ? 220_000_000 : 150_000_000)
                    guard !Task.isCancelled else {
                        return
                    }
                    isPresented = hovering
                }
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tip.title)
                        .font(.subheadline.weight(.semibold))
                    Text(tip.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let shortcut = tip.shortcut {
                        Text(shortcut)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .padding(12)
                .frame(width: 270, alignment: .leading)
            }
            .accessibilityLabel("\(tip.title). \(tip.message)")
            .onDisappear {
                hoverTask?.cancel()
            }
    }
}
