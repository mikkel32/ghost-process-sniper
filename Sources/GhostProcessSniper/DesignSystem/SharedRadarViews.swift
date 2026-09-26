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

    static func icon(for level: GhostLevel) -> String {
        switch level {
        case .quiet: "checkmark.circle"
        case .watch: "eye"
        case .hot: "flame"
        case .critical: "exclamationmark.triangle"
        }
    }
}

enum RadarTheme {
    static let brand = Color(red: 0.16, green: 0.72, blue: 0.88)
    static let brandSecondary = Color(red: 0.38, green: 0.42, blue: 0.98)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let elevatedPanel = Color(nsColor: .underPageBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)

    static func accent(for level: GhostLevel) -> Color {
        switch level {
        case .quiet: brand
        case .watch: .orange
        case .hot: .red
        case .critical: .pink
        }
    }
}

private struct RadarSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let isRaised: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surfaced = content
            .background(shape.fill(isRaised ? RadarTheme.elevatedPanel : RadarTheme.panel))
            .overlay {
                shape.strokeBorder(RadarTheme.separator.opacity(0.72), lineWidth: 0.75)
            }
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(tint)
                    .frame(width: isRaised ? 52 : 32, height: 2)
                    .padding(.leading, 14)
                    .opacity(isRaised ? 0.9 : 0.5)
            }

        if isRaised {
            surfaced.shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        } else {
            surfaced
        }
    }
}

extension View {
    func radarSurface(
        tint: Color = RadarTheme.brand,
        cornerRadius: CGFloat = 16,
        raised: Bool = false
    ) -> some View {
        modifier(RadarSurfaceModifier(tint: tint, cornerRadius: cornerRadius, isRaised: raised))
    }
}

struct RadarBrandMark: View {
    let level: GhostLevel
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .stroke(RadarTheme.accent(for: level).opacity(0.2), lineWidth: 1)
                .padding(3)
            Circle()
                .stroke(RadarTheme.accent(for: level).opacity(0.5), lineWidth: 1)
                .padding(size * 0.22)
            Image(systemName: "scope")
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(RadarTheme.accent(for: level).gradient)
        }
        .frame(width: size, height: size)
        .background(RadarTheme.accent(for: level).opacity(0.09), in: Circle())
        .overlay(Circle().strokeBorder(RadarTheme.accent(for: level).opacity(0.22), lineWidth: 0.75))
        .accessibilityHidden(true)
    }
}

struct RadarStatusPill: View {
    let title: String
    let level: GhostLevel
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(RadarTheme.accent(for: level))
                .frame(width: 6, height: 6)
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(RadarTheme.accent(for: level))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RadarTheme.accent(for: level).opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(RadarTheme.accent(for: level).opacity(0.22), lineWidth: 0.75))
    }
}

struct RadarPageHeader<Actions: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(accent.gradient)
                .frame(width: 42, height: 42)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(accent.opacity(0.22), lineWidth: 0.75)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .tracking(1.2)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            actions
        }
        .padding(14)
        .radarSurface(tint: accent, cornerRadius: 16)
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
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct CompactRadarChip: View {
    let title: String
    let value: String
    var systemImage: String?
    var level: GhostLevel = .quiet

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(RadarTheme.accent(for: level))
                        .frame(width: 19, height: 19)
                        .background(RadarTheme.accent(for: level).opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minHeight: 38, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct RadarSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tip: RadarTip?
    var accent: Color = RadarTheme.brand
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .radarSurface(tint: accent)
    }
}

struct CompactRadarSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tip: RadarTip?
    var accent: Color = RadarTheme.brand
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 24, height: 24)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .padding(13)
        .radarSurface(tint: accent, cornerRadius: 14)
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
        case .forecast: "clock.badge.exclamationmark"
        case .rules: "slider.horizontal.3"
        case .system: "gearshape.2"
        }
    }
}

struct EngineHealthStrip: View {
    let metrics: RadarPerformanceMetrics
    let health: SamplerHealth
    let storeHealth: StoreHealth

    var body: some View {
        HStack(spacing: 8) {
            RadarChip(title: "Refresh", value: "\(Int(metrics.lastRefresh.totalMilliseconds.rounded())) ms", systemImage: "timer")
            RadarChip(title: "Next", value: String(format: "%.1fs", metrics.nextRefreshInterval), systemImage: "clock.arrow.2.circlepath")
            RadarChip(title: "Processes", value: "\(health.processCount)", systemImage: "list.bullet.rectangle")
            RadarChip(title: "Scanner", value: metrics.scannerHealth.didHitDeadline ? "deferred" : "within budget", systemImage: "speedometer")
            RadarChip(title: "Backlog", value: "\(storeHealth.backlogCount + storeHealth.pendingActionCount)", systemImage: "externaldrive")
        }
        .padding(6)
        .radarSurface(tint: .teal, cornerRadius: 16)
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
        .padding(.vertical, 9)
        .radarSurface(tint: RadarTheme.brand, cornerRadius: 14)
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
            .background(RadarTheme.elevatedPanel, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75))
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

/// A two-item layout that stays horizontal when useful and collapses cleanly
/// when a sidebar or inspector narrows the content column.
struct AdaptivePairLayout: Layout {
    var breakpoint: CGFloat = 720
    var spacing: CGFloat = 14
    var secondaryWidth: CGFloat? = nil

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? breakpoint
        guard subviews.count >= 2 else {
            return subviews[0].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        }

        if width >= breakpoint {
            let secondWidth = min(secondaryWidth ?? (width - spacing) / 2, width * 0.44)
            let firstWidth = max(0, width - spacing - secondWidth)
            let first = subviews[0].sizeThatFits(ProposedViewSize(width: firstWidth, height: proposal.height))
            let second = subviews[1].sizeThatFits(ProposedViewSize(width: secondWidth, height: proposal.height))
            return CGSize(width: width, height: max(first.height, second.height))
        }

        let sizes = subviews.prefix(2).map {
            $0.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        return CGSize(width: width, height: sizes.reduce(0) { $0 + $1.height } + spacing)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        guard subviews.count >= 2 else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }

        if bounds.width >= breakpoint {
            let secondWidth = min(secondaryWidth ?? (bounds.width - spacing) / 2, bounds.width * 0.44)
            let firstWidth = max(0, bounds.width - spacing - secondWidth)
            subviews[0].place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: firstWidth, height: bounds.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + firstWidth + spacing, y: bounds.minY),
                proposal: ProposedViewSize(width: secondWidth, height: bounds.height)
            )
            return
        }

        let first = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: first.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + first.height + spacing),
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
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
