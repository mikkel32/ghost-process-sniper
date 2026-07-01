import AppKit
import GhostProcessSniperCore
import SwiftUI

@MainActor
enum RadarBytes {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func string(_ bytes: UInt64) -> String {
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

enum RadarStyle {
    static func color(for level: GhostLevel) -> Color {
        switch level {
        case .quiet: .secondary
        case .watch: .orange
        case .hot: .red
        case .critical: .pink
        }
    }

    static func glass(for level: GhostLevel) -> Glass {
        switch level {
        case .quiet:
            .regular.interactive(true)
        case .watch:
            .regular.tint(.orange.opacity(0.13)).interactive(true)
        case .hot:
            .regular.tint(.red.opacity(0.18)).interactive(true)
        case .critical:
            .regular.tint(.pink.opacity(0.22)).interactive(true)
        }
    }

    static func icon(for level: GhostLevel) -> String {
        switch level {
        case .quiet: "checkmark.circle"
        case .watch: "eye"
        case .hot: "flame"
        case .critical: "exclamationmark.triangle"
        }
    }
}

struct RadarChip: View {
    let title: String
    let value: String
    var systemImage: String?
    var level: GhostLevel = .quiet

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(RadarStyle.color(for: level))
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompactRadarChip: View {
    let title: String
    let value: String
    var systemImage: String?
    var level: GhostLevel = .quiet

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(RadarStyle.color(for: level))
                    .frame(width: 13)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .contentTransition(.numericText())
            }
        }
        .frame(minHeight: 34, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ScoreRingGauge: View {
    let score: Double
    let level: GhostLevel
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: size * 0.11)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, score / 100)))
                .stroke(
                    RadarStyle.color(for: level).gradient,
                    style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(score.rounded()))")
                .font(.system(size: size * 0.33, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(RadarStyle.color(for: level)))
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.55), value: score)
        .animation(.spring(duration: 0.55), value: level)
        .accessibilityLabel("Score \(Int(score.rounded())) of 100, \(level.label)")
    }
}

struct ScoreCapsuleBadge: View {
    let scoreText: String
    let level: GhostLevel

    var body: some View {
        Text(scoreText)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(level == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(RadarStyle.color(for: level)))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RadarStyle.color(for: level).opacity(level == .quiet ? 0.07 : 0.14),
                in: Capsule()
            )
            .contentTransition(.numericText())
    }
}

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
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(isPresented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
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
    }
}

struct RadarSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tip: RadarTip?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let tip {
                    InfoTip(tip: tip)
                }
                Spacer()
            }
            content
        }
        .padding(14)
        .glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CompactRadarSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tip: RadarTip?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let tip {
                    InfoTip(tip: tip)
                }
                Spacer()
            }
            content
        }
        .padding(12)
        .glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct FamilyTriageRow: View {
    let item: FamilyTriageViewModel
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(RadarStyle.color(for: item.level))
                .frame(width: 4, height: 42)
                .shadow(color: RadarStyle.color(for: item.level).opacity(item.level == .quiet ? 0 : 0.45), radius: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: RadarStyle.icon(for: item.level))
                        .foregroundStyle(RadarStyle.color(for: item.level))
                        .frame(width: 15)
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Int(item.score.rounded()).description)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(RadarStyle.color(for: item.level))
                }

                Text(item.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    metric(item.kindText, "tag")
                    if item.forecastState >= .warming {
                        metric("\(item.forecastText) \(item.etaText)", "clock.badge.exclamationmark")
                    }
                    metric(item.memoryText, "memorychip")
                    metric(item.cpuText, "cpu")
                    if item.gpuPercent > 0.5 {
                        metric("GPU \(item.gpuText)", "display")
                    }
                    metric(item.leakText, "chart.line.uptrend.xyaxis")
                    if item.childCount > 0 {
                        metric("\(item.childCount)", "point.3.connected.trianglepath.dotted")
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(isSelected ? 1 : 0.96)
    }

    private func metric(_ value: String, _ image: String) -> some View {
        Label(value, systemImage: image)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

struct ScoreComponentView: View {
    let component: GhostScoreComponent

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(RadarStyle.color(for: component.level))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(component.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("+\(Int(component.impact.rounded()))")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var icon: String {
        switch component.kind {
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .gpu: "display"
        case .leak: "chart.line.uptrend.xyaxis"
        case .baseline: "ruler"
        case .fanout: "point.3.connected.trianglepath.dotted"
        case .background: "moon"
        case .recurrence: "repeat"
        case .rules: "slider.horizontal.3"
        case .system: "gearshape.2"
        }
    }
}

struct TrendSparkline: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        guard points.count >= 2 else {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }

        let minValue = points.min() ?? 0
        let maxValue = points.max() ?? 1
        let span = max(maxValue - minValue, 1)
        var path = Path()

        for (index, value) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = rect.maxY - rect.height * CGFloat((value - minValue) / span)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }
}

struct EngineHealthStrip: View {
    let metrics: RadarPerformanceMetrics
    let health: SamplerHealth
    let storeHealth: StoreHealth

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                RadarChip(title: "Refresh", value: "\(Int(metrics.lastRefresh.totalMilliseconds.rounded())) ms", systemImage: "timer")
                RadarChip(title: "Next", value: String(format: "%.1fs", metrics.nextRefreshInterval), systemImage: "clock.arrow.2.circlepath")
                RadarChip(title: "Processes", value: "\(health.processCount)", systemImage: "list.bullet.rectangle")
                RadarChip(title: "Scanner", value: metrics.scannerHealth.didHitDeadline ? "deferred" : "within budget", systemImage: "speedometer")
                RadarChip(title: "Backlog", value: "\(storeHealth.backlogCount + storeHealth.pendingActionCount)", systemImage: "externaldrive")
            }
            .glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct CompactEngineHealthStrip: View {
    let status: EngineStatusSnapshot

    var body: some View {
        HStack(spacing: 10) {
            CompactRadarChip(title: "Refresh", value: status.refreshText, systemImage: "timer")
            CompactRadarChip(title: "Next", value: status.nextRefreshText, systemImage: "clock.arrow.2.circlepath")
            CompactRadarChip(title: "Processes", value: status.processText, systemImage: "list.bullet.rectangle")
            CompactRadarChip(title: "Scanner", value: status.scannerText, systemImage: "speedometer", level: status.scannerText == "within budget" ? .quiet : .watch)
            CompactRadarChip(title: "Backlog", value: status.backlogText, systemImage: "externaldrive")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct RadarToastView: View {
    let toast: RadarToast

    var body: some View {
        Label(toast.message, systemImage: toast.systemImage)
            .font(.callout.weight(.medium))
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(true), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.bottom, 16)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

private let snoozeChoices: [(label: String, minutes: TimeInterval)] = [
    ("15 Minutes", 15),
    ("1 Hour", 60),
    ("4 Hours", 240),
    ("Until Tomorrow", 24 * 60)
]

struct FamilySnoozeMenu: View {
    let snooze: (TimeInterval) -> Void

    var body: some View {
        ForEach(snoozeChoices, id: \.minutes) { choice in
            Button(choice.label) {
                snooze(choice.minutes)
            }
        }
    }
}

private struct FamilyRowActionsModifier: ViewModifier {
    let row: CompactSidebarRowModel
    let session: RadarConsoleSession

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                session.focus(.family(row.id))
            } label: {
                Label("Show Details", systemImage: "sidebar.right")
            }

            Menu {
                FamilySnoozeMenu { minutes in
                    session.snooze(familyKey: row.id, name: row.title, minutes: minutes)
                }
            } label: {
                Label("Snooze", systemImage: "moon")
            }

            Button {
                session.ignore(familyKey: row.id, name: row.title)
            } label: {
                Label("Ignore Family", systemImage: "eye.slash")
            }

            Divider()

            Button(role: .destructive) {
                session.prepareKill(familyKey: row.id)
            } label: {
                Label("Kill Preview…", systemImage: "scope")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(row.title) — \(row.subtitle)\n\(row.metricText)", forType: .string)
                session.showToast("Copied \(row.title) summary", systemImage: "doc.on.clipboard")
            } label: {
                Label("Copy Summary", systemImage: "doc.on.clipboard")
            }
        }
    }
}

extension View {
    func familyRowActions(row: CompactSidebarRowModel, session: RadarConsoleSession) -> some View {
        modifier(FamilyRowActionsModifier(row: row, session: session))
    }
}

/// A left-to-right layout that wraps to new rows instead of clipping —
/// evidence tags stay readable no matter how many there are.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? usedWidth : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct FlowTags: View {
    let title: String
    let items: [String]

    var body: some View {
        WrappingHStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            ForEach(items.prefix(10), id: \.self) { item in
                Text(item)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}
