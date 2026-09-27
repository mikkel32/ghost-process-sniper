import AppKit
import GhostProcessSniperCore
import SwiftUI

/// Launch agents and daemons: flagged and new ones first, the rest folded.
struct SentinelStartupItems: View {
    let items: [LaunchItem]
    @State private var showsAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notable = items.filter { $0.severity >= .notable || $0.isNew }
        let rest = items.filter { !($0.severity >= .notable || $0.isNew) }
        RadarSection(
            title: "Starts automatically",
            subtitle: summary(notable: notable.count),
            systemImage: "arrow.clockwise.circle",
            accent: notable.contains { $0.severity >= .suspicious } ? .orange : RadarTheme.brand
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notable) { SentinelStartupRow(item: $0) }
                if !rest.isEmpty {
                    DisclosureGroup(isExpanded: $showsAll.animation(RadarMotion.response(reduceMotion))) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rest) { SentinelStartupRow(item: $0) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(rest.count == 1 ? "1 more that looks normal" : "\(rest.count) more that look normal")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if items.isEmpty {
                    Text("No launch agents or daemons are installed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summary(notable: Int) -> String {
        let total = items.count == 1 ? "1 item" : "\(items.count) items"
        return notable == 0 ? "\(total), none unusual · new ones are caught the moment they appear"
            : "\(total) · \(notable) worth a look"
    }
}

struct SentinelStartupRow: View {
    let item: LaunchItem
    @State private var expanded = false

    private var tint: Color { SentinelStyle.color(for: item.severity) }
    private var flagged: [SentinelSignal] { item.signals.filter { $0.severity >= .notable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    SentinelProgramIcon(path: item.programPath, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.label)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if item.isNew {
                                Text("NEW")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(tint.gradient, in: Capsule())
                            }
                            ForEach(flagged.prefix(3), id: \.kind) { signal in
                                Image(systemName: signal.kind.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(SentinelStyle.color(for: signal.severity))
                                    .help(signal.kind.title)
                            }
                        }
                        Text(item.programPath.isEmpty ? "No program set" : item.programPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Text(item.scope.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RadarRowButtonStyle())

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(flagged.enumerated()), id: \.offset) { _, signal in
                        SentinelSignalRow(signal: signal)
                    }
                    Text(item.commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(spacing: 12) {
                        if let signing = item.signing {
                            Label(signing.label, systemImage: "signature")
                        }
                        if item.runsAtLoad { Label("Runs at load", systemImage: "power") }
                        if item.keepsAlive { Label("Restarted if it quits", systemImage: "arrow.triangle.2.circlepath") }
                        Spacer()
                        Button("Reveal Plist") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
                        }
                        .controlSize(.small)
                        .help("Shows the file in Finder. Moving it to the Trash and logging out stops it from starting.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 32)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
