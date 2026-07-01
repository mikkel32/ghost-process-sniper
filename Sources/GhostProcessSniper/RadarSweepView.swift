import AppKit
import GhostProcessSniperCore
import QuartzCore
import SwiftUI

/// A live radar scope: concentric range rings, a rotating sweep beam, and one
/// blip per tracked family. Blip distance from center encodes risk (hotter
/// families close in on the center) and the angle is a stable hash of the
/// family key so blips do not jump between refreshes.
///
/// Self-cost design: the only continuously animating element is the beam,
/// a CAGradientLayer spun by a CABasicAnimation. That animation is committed
/// once and runs on the render server — the app process burns no CPU per
/// frame. (Two earlier versions got this wrong: a 30 fps TimelineView Canvas
/// redraw, then a SwiftUI repeatForever rotationEffect — both re-ran layout
/// on the CPU every display frame and cost most of a core.) The scope
/// background is a static Canvas and blips are plain views that only
/// re-render when the underlying data changes.
struct RadarSweepView: View {
    @Bindable var session: RadarConsoleSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sweepPeriod: TimeInterval = 5.5

    private var rows: [CompactSidebarRowModel] {
        Array(session.compactFamilyItems.prefix(24))
    }

    private var accent: Color {
        let level = session.commandCenter.level
        return level == .quiet ? .teal : RadarStyle.color(for: level)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 10
            ZStack {
                scopeBackground
                if !reduceMotion {
                    beamLayer(center: center, radius: radius)
                }
                ForEach(rows) { row in
                    RadarBlip(row: row, session: session)
                        .position(Self.blipPosition(key: row.id, score: row.scoreValue, in: size))
                }
                if rows.isEmpty {
                    VStack(spacing: 4) {
                        Text("No active targets")
                            .font(.caption.weight(.semibold))
                        Text("Families appear here as blips when tracked")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel("Live radar with \(rows.count) tracked families")
    }

    // Rings, crosshairs, and hub. Static — SwiftUI only redraws this when
    // the accent color or layout changes.
    private var scopeBackground: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 10
            guard radius > 20 else {
                return
            }
            let scopeRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            for fraction in [0.33, 0.66] {
                let ringRadius = radius * fraction
                let rect = CGRect(
                    x: center.x - ringRadius,
                    y: center.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                )
                context.stroke(Path(ellipseIn: rect), with: .color(accent.opacity(0.14)), lineWidth: 1)
            }
            context.stroke(Path(ellipseIn: scopeRect), with: .color(accent.opacity(0.3)), lineWidth: 1.4)

            var crosshair = Path()
            crosshair.move(to: CGPoint(x: center.x - radius, y: center.y))
            crosshair.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            crosshair.move(to: CGPoint(x: center.x, y: center.y - radius))
            crosshair.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            context.stroke(crosshair, with: .color(accent.opacity(0.09)), lineWidth: 1)

            let hubRect = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: hubRect), with: .color(accent.opacity(0.9)))
        }
        .allowsHitTesting(false)
    }

    // The beam: a conic-gradient CALayer spun by one CABasicAnimation, so
    // the rotation runs entirely on the render server.
    private func beamLayer(center: CGPoint, radius: CGFloat) -> some View {
        RotatingBeamLayer(color: NSColor(accent), period: Self.sweepPeriod)
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
            .allowsHitTesting(false)
    }

    static func blipPosition(key: String, score: Double, in size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 10
        let angle = stableAngle(for: key)
        // Score 100 sits near the hub, score 0 out at the rim.
        let distance = radius * (0.16 + (1 - min(1, max(0, score / 100))) * 0.74)
        return CGPoint(
            x: center.x + cos(angle) * distance,
            y: center.y + sin(angle) * distance
        )
    }

    // FNV-1a: deterministic across launches, unlike Swift's seeded hashing,
    // so a family keeps its bearing on the scope forever.
    static func stableAngle(for key: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Double(hash % 3600) / 3600 * 2 * .pi
    }
}

/// A conic gradient (bright leading edge fading into a trail) rotated by a
/// single committed CABasicAnimation. Zero per-frame app CPU.
private struct RotatingBeamLayer: NSViewRepresentable {
    let color: NSColor
    let period: TimeInterval

    func makeNSView(context: Context) -> BeamLayerView {
        BeamLayerView()
    }

    func updateNSView(_ view: BeamLayerView, context: Context) {
        view.configure(color: color, period: period)
    }
}

final class BeamLayerView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private var configuredColor: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.mask = maskLayer
        layer?.addSublayer(gradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        maskLayer.frame = gradientLayer.bounds
        maskLayer.path = CGPath(ellipseIn: gradientLayer.bounds, transform: nil)
        CATransaction.commit()
        ensureRotation()
    }

    func configure(color: NSColor, period: TimeInterval) {
        if configuredColor != color {
            configuredColor = color
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradientLayer.colors = [
                color.withAlphaComponent(0.85).cgColor,
                color.withAlphaComponent(0.34).cgColor,
                color.withAlphaComponent(0).cgColor,
                color.withAlphaComponent(0).cgColor
            ]
            gradientLayer.locations = [0, 0.02, 0.26, 1]
            CATransaction.commit()
        }
        ensureRotation(period: period)
    }

    private func ensureRotation(period: TimeInterval = 5.5) {
        guard gradientLayer.animation(forKey: "sweep") == nil else {
            return
        }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -2 * Double.pi
        rotation.duration = period
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        gradientLayer.add(rotation, forKey: "sweep")
    }
}

/// One family on the scope. Hot blips get a wider static glow (continuous
/// per-blip animation is deliberately avoided — it would tick SwiftUI every
/// display frame); every blip is clickable with the standard family menu.
private struct RadarBlip: View {
    let row: CompactSidebarRowModel
    let session: RadarConsoleSession

    private var color: Color {
        row.level == .quiet ? .teal : RadarStyle.color(for: row.level)
    }

    private var coreSize: CGFloat {
        row.level >= .hot ? 9.2 : 6.8
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(row.level >= .hot ? 0.3 : 0.18))
                .frame(width: coreSize + (row.level >= .hot ? 14 : 9), height: coreSize + (row.level >= .hot ? 14 : 9))
            Circle()
                .fill(color.opacity(0.85))
                .frame(width: coreSize, height: coreSize)
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .onTapGesture {
            session.focus(.family(row.id))
        }
        .familyRowActions(row: row, session: session)
        .help("\(row.title) — score \(row.scoreText)\n\(row.metricText)")
        .accessibilityLabel("\(row.title), score \(row.scoreText)")
    }
}
