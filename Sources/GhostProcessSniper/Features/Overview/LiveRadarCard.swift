import GhostProcessSniperCore
import SwiftUI

/// The scope beside the contacts it shows, worst first. Pointing at a row
/// lights its blip and the other way round; clicking either opens the family.
struct LiveRadarCard: View {
    let session: RadarConsoleSession
    @State private var hoveredID: String?

    var body: some View {
        let rows = session.compactSnapshot.allRows
        CompactRadarSection(
            title: "Live Radar",
            subtitle: Self.summary(rows),
            systemImage: "dot.radiowaves.left.and.right",
            tip: RadarTip(
                title: "Live Radar",
                message: "Rings are verdicts: Critical at the center, then Hot, Watch and Quiet. Quarters say what a family is: apps, servers, developer tools or background work. A bigger blip uses more memory, and a streak shows where a family was five minutes ago, so a streak pointing inward means it is getting worse. Point at a blip or a contact to see why it is there; click to open it, right-click to snooze, ignore or stop it.",
                shortcut: "⌘1 Overview"
            ),
            accent: RadarTheme.accent(for: session.commandCenter.level)
        ) {
            AdaptivePairLayout(breakpoint: 560, spacing: 18, secondaryWidth: 250) {
                LiveRadarScope(rows: rows, history: session.radarHistory, session: session, hoveredID: $hoveredID)
                    .frame(minWidth: 260, maxWidth: .infinity)
                    .frame(height: 360)
                LiveRadarContacts(rows: rows, history: session.radarHistory, session: session, hoveredID: $hoveredID)
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                Label("The sweep rests in Low Power Mode; blips still move with every scan.", systemImage: "leaf")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// "1 hot · 2 watch · 17 quiet": the rings' contents, worst first.
    static func summary(_ rows: [CompactSidebarRowModel]) -> String {
        guard !rows.isEmpty else { return "nothing tracked yet" }
        let counts = Dictionary(grouping: rows, by: \.level).mapValues(\.count)
        return [GhostLevel.critical, .hot, .watch, .quiet]
            .compactMap { level in counts[level].map { "\($0) \(LiveRadarBands.name(level).lowercased())" } }
            .joined(separator: " \u{00B7} ")
    }
}

/// The contacts that matter, in the order the scope names them.
private struct LiveRadarContacts: View {
    let rows: [CompactSidebarRowModel]
    let history: LiveRadarHistory
    let session: RadarConsoleSession
    @Binding var hoveredID: String?

    static let shown = 6

    var body: some View {
        let inputs = rows.map(LiveRadarInput.init(row:))
        let ranked = LiveRadarScene.ranked(inputs, history: history).prefix(Self.shown)
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 2) {
            Text("CONTACTS")
                .font(.caption2.weight(.bold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            ForEach(Array(ranked), id: \.id) { input in
                if let row = rowsByID[input.id] {
                    LiveRadarContactRow(row: row, trend: LiveRadarScene.trend(of: input, history: history),
                                        session: session, isHighlighted: hoveredID == input.id) {
                        hoveredID = $0 ? input.id : (hoveredID == input.id ? nil : hoveredID)
                    }
                    .equatable()
                }
            }
            if rows.count > ranked.count {
                Text("\(rows.count - ranked.count) more on the scope")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveRadarContactRow: View, Equatable {
    let row: CompactSidebarRowModel
    let trend: LiveRadarTrend
    let session: RadarConsoleSession
    let isHighlighted: Bool
    let onHover: (Bool) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row.title == rhs.row.title && lhs.row.statusText == rhs.row.statusText && lhs.row.level == rhs.row.level &&
            LiveRadarStyle.memory(lhs.row.memoryBytes) == LiveRadarStyle.memory(rhs.row.memoryBytes) &&
            lhs.row.radarSector == rhs.row.radarSector && lhs.trend == rhs.trend && lhs.isHighlighted == rhs.isHighlighted
    }

    var body: some View {
        let color = LiveRadarStyle.color(row.level)
        Button {
            session.focus(.family(row.id))
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.statusText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(row.level == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                    }
                    HStack(spacing: 5) {
                        // What the scope shows, not the live CPU the sidebar
                        // already has: this text changes only when the blip does.
                        Text("\(LiveRadarStyle.memory(row.memoryBytes)) \u{00B7} \(row.radarSector.label)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let trendText {
                            Text(trendText)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(trend == .closing ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                        }
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(isHighlighted ? AnyShapeStyle(color.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .familyRowActions(row: row, session: session)
        .accessibilityLabel("\(row.title), \(row.statusText), \(LiveRadarStyle.memory(row.memoryBytes))\(trendText.map { ", \($0)" } ?? "")")
    }

    private var trendText: String? {
        switch trend {
        case .closing: "closing in"
        case .easing: "easing"
        case .steady: nil
        }
    }
}

/// Depends only on what it draws: a scan that changes a family's numbers
/// but not its place, size, level or name does not redraw its blip.
struct LiveRadarBlip: View, Equatable {
    let contact: LiveRadarContact
    let row: CompactSidebarRowModel
    let session: RadarConsoleSession
    let isHighlighted: Bool
    let onHover: (Bool) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contact == rhs.contact && lhs.isHighlighted == rhs.isHighlighted && lhs.row.title == rhs.row.title &&
            lhs.row.statusText == rhs.row.statusText
    }

    var body: some View {
        let color = LiveRadarStyle.color(contact.level)
        let size = contact.diameter
        Button {
            session.focus(.family(row.id))
        } label: {
            ZStack {
                if contact.level >= .watch {
                    Circle()
                        .fill(color.opacity(contact.level >= .hot ? 0.2 : 0.13))
                        .frame(width: size * 2.3, height: size * 2.3)
                }
                Circle()
                    .fill(color.opacity(contact.level == .quiet ? 0.75 : 1))
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                if isHighlighted {
                    Circle()
                        .strokeBorder(color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                        .frame(width: size + 12, height: size + 12)
                }
                if contact.trend != .steady {
                    trendMark(color: color)
                }
            }
            .frame(width: max(24, size * 2.3), height: max(24, size * 2.3))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .familyRowActions(row: row, session: session)
        .accessibilityLabel("\(row.title), \(row.statusText), \(contact.sector.label)")
    }

    /// A small arrowhead on the side it is heading: toward the center when
    /// getting worse, away from it when easing.
    private func trendMark(color: Color) -> some View {
        let inward = contact.trend == .closing
        let direction = inward ? contact.bearing + .pi : contact.bearing
        let reach = contact.diameter / 2 + 5
        return Image(systemName: "arrowtriangle.forward.fill")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(inward ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
            .rotationEffect(.radians(direction))
            .offset(x: cos(direction) * reach, y: sin(direction) * reach)
    }
}

struct LiveRadarCallout: View {
    let row: CompactSidebarRowModel
    let contact: LiveRadarContact

    static let width: CGFloat = 216

    var body: some View {
        let color = LiveRadarStyle.color(contact.level)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(row.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(row.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(contact.level == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
            }
            Text(row.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.metricText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(contact.sector.label) \u{00B7} \(Self.movement(contact.trend))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(9)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(RadarTheme.separator.opacity(0.8), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    static func movement(_ trend: LiveRadarTrend) -> String {
        switch trend {
        case .closing: "getting worse"
        case .easing: "easing off"
        case .steady: "holding steady"
        }
    }
}
