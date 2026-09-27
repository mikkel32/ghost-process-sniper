import AppKit
import GhostProcessSniperCore
import SwiftUI

/// The Live Radar's scope. Rings are verdicts (Critical at the center, then
/// Hot, Watch and Quiet), quarters are what a family is, a blip's size is
/// its memory, a streak is where it was five minutes ago, and the names of
/// what matters sit beside their blips. The layout is `LiveRadarScene`'s.
struct LiveRadarScope: View {
    let rows: [CompactSidebarRowModel]
    let history: LiveRadarHistory
    let session: RadarConsoleSession
    @Binding var hoveredID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isInViewport = false

    var body: some View {
        GeometryReader { proxy in
            let scene = LiveRadarScene.build(rows.map(LiveRadarInput.init(row:)), history: history,
                                             width: proxy.size.width, height: proxy.size.height)
            let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ZStack(alignment: .topLeading) {
                LiveRadarFace(width: scene.width, height: scene.height, radius: scene.radius)
                    .equatable()
                if !reduceMotion {
                    RadarSweepLayer(centerX: scene.centerX, centerY: scene.centerY, radius: scene.radius,
                                    glows: scene.contacts.map(Self.glow), beamColor: NSColor(RadarTheme.brand),
                                    inViewport: isInViewport && !scene.contacts.isEmpty)
                }
                LiveRadarTrails(scene: scene)
                ForEach(scene.contacts) { contact in
                    if let row = rowsByID[contact.id] {
                        LiveRadarBlip(contact: contact, row: row, session: session, isHighlighted: hoveredID == contact.id) {
                            hoveredID = $0 ? contact.id : (hoveredID == contact.id ? nil : hoveredID)
                        }
                        .position(x: contact.x, y: contact.y)
                    }
                }
                ForEach(scene.contacts.filter { $0.label != nil }) { contact in
                    if let label = contact.label {
                        LiveRadarName(label: label, level: contact.level, isHighlighted: hoveredID == contact.id)
                    }
                }
                if let contact = scene.contacts.first(where: { $0.id == hoveredID }), let row = rowsByID[contact.id] {
                    LiveRadarCallout(row: row, contact: contact)
                        .position(Self.calloutPosition(for: contact, in: scene))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if scene.contacts.isEmpty, scene.radius > 0 {
                    Text(session.compactSnapshot.hasSampled ? "Nothing to track" : "Scanning\u{2026}")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .position(x: scene.centerX, y: scene.centerY + 26)
                }
            }
            .animation(RadarMotion.reading(reduceMotion), value: scene.contacts)
        }
        .onScrollVisibilityChange(threshold: 0.05) { isInViewport = $0 }
        .onDisappear { isInViewport = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live radar")
    }

    static func glow(_ contact: LiveRadarContact) -> RadarSweepLayer.Glow {
        RadarSweepLayer.Glow(id: contact.id, x: contact.x, y: contact.y, bearing: contact.bearing,
                             diameter: contact.diameter, color: NSColor(LiveRadarStyle.color(contact.level)))
    }

    /// Beside the blip on the side facing the center, kept inside the scope.
    static func calloutPosition(for contact: LiveRadarContact, in scene: LiveRadarScene) -> CGPoint {
        let halfWidth = LiveRadarCallout.width / 2
        let offset = halfWidth + contact.diameter / 2 + 14
        let x = contact.x >= scene.centerX ? contact.x - offset : contact.x + offset
        return CGPoint(x: min(max(x, halfWidth + 2), max(halfWidth + 2, scene.width - halfWidth - 2)),
                       y: min(max(contact.y, 44), max(44, scene.height - 44)))
    }
}

enum LiveRadarStyle {
    /// Quiet blips wear the brand color: grey dots would read as disabled.
    static func color(_ level: GhostLevel) -> Color {
        level == .quiet ? RadarTheme.brand : RadarStyle.color(for: level)
    }

}

/// Rings, their verdicts, the quarters and the rim. It changes only with
/// the scope's size.
private struct LiveRadarFace: View, Equatable {
    let width: Double
    let height: Double
    let radius: Double

    var body: some View {
        Canvas { context, _ in
            guard radius > 24 else { return }
            let center = CGPoint(x: width / 2, y: height / 2)
            func circle(_ fraction: Double) -> Path {
                let reach = radius * fraction
                return Path(ellipseIn: CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2))
            }
            // Verdict rings, innermost first, each faintly tinted by its level.
            for level in [GhostLevel.watch, .hot, .critical] {
                let band = LiveRadarBands.band(level)
                let tint = LiveRadarStyle.color(level)
                var ring = circle(band.upperBound)
                if level != .critical { ring.addPath(circle(band.lowerBound)) }
                context.fill(ring, with: .color(tint.opacity(level == .critical ? 0.075 : 0.045)), style: FillStyle(eoFill: true))
                context.stroke(circle(band.upperBound), with: .color(tint.opacity(0.28)), lineWidth: 0.8)
            }
            context.stroke(circle(1), with: .color(RadarTheme.brand.opacity(0.34)), lineWidth: 1.2)

            // Quarters: the crosshair divides what a family is.
            var dividers = Path()
            dividers.move(to: CGPoint(x: center.x - radius, y: center.y))
            dividers.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            dividers.move(to: CGPoint(x: center.x, y: center.y - radius))
            dividers.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            context.stroke(dividers, with: .color(RadarTheme.brand.opacity(0.13)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))

            var minor = Path()
            var major = Path()
            for index in 0..<72 {
                let angle = Double(index) / 72 * 2 * .pi
                let isMajor = index.isMultiple(of: 6)
                let outer = radius + 6
                let inner = outer - (isMajor ? 5 : 2.5)
                let start = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
                let end = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
                if isMajor { major.move(to: start); major.addLine(to: end) } else { minor.move(to: start); minor.addLine(to: end) }
            }
            context.stroke(minor, with: .color(RadarTheme.brand.opacity(0.2)), lineWidth: 0.7)
            context.stroke(major, with: .color(RadarTheme.brand.opacity(0.45)), lineWidth: 1)

            // Each ring's verdict, on the 12 o'clock line just inside its edge.
            for level in [GhostLevel.critical, .hot, .watch, .quiet] {
                let text = Text(LiveRadarBands.name(level))
                    .font(.system(size: 7.5, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(LiveRadarStyle.color(level).opacity(level == .quiet ? 0.55 : 0.8))
                let point = LiveRadarScene.bandLabelPoint(level, centerX: center.x, centerY: center.y, radius: radius)
                context.draw(text, at: CGPoint(x: point.x, y: point.y), anchor: .center)
            }
            for sector in LiveRadarSector.allCases {
                let point = LiveRadarScene.sectorLabelPoint(sector, centerX: center.x, centerY: center.y, radius: radius)
                context.draw(Text(sector.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary),
                             at: CGPoint(x: point.x, y: point.y), anchor: .center)
            }
            context.fill(circle(0.018), with: .color(RadarTheme.brand.opacity(0.9)))
        }
        .allowsHitTesting(false)
    }
}

/// Where each moving family was five minutes ago: a streak that brightens
/// toward the blip. A streak from the rim inward means it is getting worse.
/// Also the lines from names set in the margin to their blips.
private struct LiveRadarTrails: View {
    let scene: LiveRadarScene

    var body: some View {
        Canvas { context, _ in
            for contact in scene.contacts {
                guard let label = contact.label, label.hasLeader else { continue }
                let start = CGPoint(x: label.anchor == .start ? label.x - 3 : label.x + 3, y: label.y)
                let dx = contact.x - start.x
                let dy = contact.y - start.y
                let length = max(1, hypot(dx, dy))
                let end = CGPoint(x: contact.x - dx / length * (contact.diameter / 2 + 2), y: contact.y - dy / length * (contact.diameter / 2 + 2))
                var leader = Path()
                leader.move(to: start)
                leader.addLine(to: end)
                context.stroke(leader, with: .color(LiveRadarStyle.color(contact.level).opacity(0.5)), lineWidth: 0.75)
            }
            for contact in scene.contacts {
                guard let trailX = contact.trailX, let trailY = contact.trailY else { continue }
                let color = LiveRadarStyle.color(contact.level)
                var path = Path()
                path.move(to: CGPoint(x: trailX, y: trailY))
                path.addLine(to: CGPoint(x: contact.x, y: contact.y))
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [color.opacity(0), color.opacity(0.45)]),
                    startPoint: CGPoint(x: trailX, y: trailY), endPoint: CGPoint(x: contact.x, y: contact.y))
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct LiveRadarName: View {
    let label: LiveRadarLabel
    let level: GhostLevel
    let isHighlighted: Bool

    var body: some View {
        Text(label.text)
            .font(.system(size: 10, weight: level >= .watch || isHighlighted ? .semibold : .medium))
            .foregroundStyle(level >= .watch || isHighlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
            .frame(width: 1, height: 1, alignment: Self.alignment(label.anchor))
            .position(x: label.x, y: label.y)
            .allowsHitTesting(false)
    }

    static func alignment(_ anchor: LiveRadarLabel.Anchor) -> Alignment {
        switch anchor {
        case .start: .leading
        case .end: .trailing
        case .middle: .center
        }
    }
}
