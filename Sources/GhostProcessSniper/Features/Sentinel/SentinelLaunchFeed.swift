import GhostProcessSniperCore
import SwiftUI

enum SentinelFeedFilter: String, CaseIterable, Identifiable {
    case flagged
    case commands
    case all

    var id: Self { self }

    var label: String {
        switch self {
        case .flagged: "Flagged"
        case .commands: "Commands"
        case .all: "Everything"
        }
    }

    func includes(_ event: LaunchEvent) -> Bool {
        switch self {
        case .flagged: event.severity >= .notable
        case .commands: event.severity >= .notable || !event.executablePath.contains(".app/")
        case .all: true
        }
    }
}

/// Every new process, newest first: what started, what started it, and
/// whether it looks wrong. New rows arrive with a brief highlight.
struct SentinelLaunchFeed: View {
    let launches: [LaunchEvent]
    let perMinute: Int
    let onSelect: (LaunchEvent) -> Void
    @State private var filter: SentinelFeedFilter = .commands
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let visibleLimit = 120

    var body: some View {
        let shown = Array(launches.lazy.filter { filter.includes($0) }.prefix(Self.visibleLimit))
        RadarSection(
            title: "Launch feed",
            subtitle: perMinute == 1 ? "1 new process in the last minute" : "\(perMinute) new processes in the last minute",
            systemImage: "list.bullet.below.rectangle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(SentinelFeedFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)

                if shown.isEmpty {
                    ContentUnavailableView {
                        Label(filter == .flagged ? "Nothing flagged" : "No new processes yet", systemImage: "checkmark.shield")
                    } description: {
                        Text(filter == .flagged
                             ? "New processes appear here the moment Sentinel sees something worth a look."
                             : "Anything that starts from now on appears here, including commands that finish in under a second.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { event in
                            Button { onSelect(event) } label: { SentinelLaunchRow(event: event) }
                                .buttonStyle(RadarRowButtonStyle())
                                .transition(reduceMotion ? .opacity : .asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity))
                        }
                    }
                    .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.18), value: shown.first?.id)
                }
            }
        }
    }
}

struct SentinelLaunchRow: View {
    let event: LaunchEvent
    @State private var highlight = 0.0

    private var tint: Color { SentinelStyle.color(for: event.severity) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(event.at, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Circle()
                .fill(event.severity >= .notable ? tint : Color.primary.opacity(0.18))
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            SentinelProgramIcon(path: event.executablePath, size: 18)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let parent = event.parentName {
                        Text("from \(parent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if event.source == .spawnWatch {
                        Label(event.exitedAfter.map { $0 < 1 ? "caught live · ran <1 s" : "caught live" } ?? "caught live",
                              systemImage: "bolt.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RadarTheme.brand)
                            .help("Seen the moment it started, before the next scan")
                    }
                    ForEach(event.signalKinds.prefix(3), id: \.self) { kind in
                        Image(systemName: kind.systemImage)
                            .font(.caption2)
                            .foregroundStyle(tint)
                            .help(kind.title)
                    }
                }
                Text(event.commandLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RadarTheme.brand.opacity(0.14 * highlight), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onAppear {
            // Only rows that just arrived flash; scrolling old rows into view does not.
            guard Date().timeIntervalSince(event.at) < 4 else { return }
            highlight = 1
            withAnimation(.easeOut(duration: 1.8)) { highlight = 0 }
        }
        .accessibilityElement(children: .combine)
    }
}
