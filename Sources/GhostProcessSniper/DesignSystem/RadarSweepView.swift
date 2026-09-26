import AppKit
import GhostProcessSniperCore
import QuartzCore
import SwiftUI

/// A live radar scope: concentric range rings, a rotating sweep beam, and one
/// blip per tracked family. Blip distance from center encodes risk (hotter
/// families close in on the center) and the angle is a stable hash of the
/// family key so blips do not jump between refreshes.
///
/// The continuous beam uses a committed Core Animation transform, rather
/// than a per-frame SwiftUI timer. Offscreen/inactive/low-power scopes pause;
/// sampled blip positions use short, interruptible animations independently.
struct RadarSweepView: View {
    let rows: [CompactSidebarRowModel]
    let session: RadarConsoleSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isInViewport = false
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private static let sweepPeriod: TimeInterval = 5.5

    private var accent: Color {
        RadarTheme.brand
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(0, min(size.width, size.height) / 2 - 16)
            ZStack {
                scopeBackground
                if !reduceMotion {
                    beamLayer(center: center, radius: radius)
                }
                ForEach(rows) { row in
                    RadarBlip(row: row, session: session)
                        .position(Self.blipPosition(key: row.id, heat: row.heatValue, in: size))
                        .animation(RadarMotion.reading(reduceMotion), value: row.heatValue)
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
        .overlay(alignment: .topLeading) {
            if reduceMotion || isLowPower {
                Label(reduceMotion ? "Reduced motion" : "Power saving", systemImage: reduceMotion ? "pause.circle" : "leaf")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.background.opacity(0.75), in: Capsule())
                    .help("The decorative sweep is paused. Live process monitoring continues.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onScrollVisibilityChange(threshold: 0.05) { isInViewport = $0 }
        .onDisappear { isInViewport = false }
        .accessibilityLabel("Live radar with \(rows.count) tracked families")
    }

    // Rings, crosshairs, and hub. Static — SwiftUI only redraws this when
    // the accent color or layout changes.
    private var scopeBackground: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 16
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

            var minorTicks = Path()
            var majorTicks = Path()
            for index in 0..<60 {
                let angle = Double(index) / 60 * 2 * .pi
                let major = index.isMultiple(of: 5)
                let outer = radius + 7
                let inner = outer - (major ? 5.0 : 2.5)
                let start = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
                let end = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
                if major { majorTicks.move(to: start); majorTicks.addLine(to: end) }
                else { minorTicks.move(to: start); minorTicks.addLine(to: end) }
            }
            context.stroke(minorTicks, with: .color(accent.opacity(0.18)), lineWidth: 0.75)
            context.stroke(majorTicks, with: .color(accent.opacity(0.48)), lineWidth: 1)

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
        RotatingBeamLayer(color: NSColor(accent), period: Self.sweepPeriod, inViewport: isInViewport && !rows.isEmpty)
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
            .allowsHitTesting(false)
    }

    static func blipPosition(key: String, heat: Double, in size: CGSize) -> CGPoint {
        RadarScopeGeometry.position(key: key, urgency: heat, width: size.width, height: size.height)
    }

    // FNV-1a: deterministic across launches, unlike Swift's seeded hashing,
    // so a family keeps its bearing on the scope forever.
}

/// The beam keeps its local animation time when paused, so resuming does
/// not snap the leading edge back to its original bearing.
private struct RotatingBeamLayer: NSViewRepresentable {
    let color: NSColor
    let period: TimeInterval
    let inViewport: Bool

    func makeNSView(context: Context) -> BeamLayerView {
        BeamLayerView()
    }

    func updateNSView(_ view: BeamLayerView, context: Context) {
        view.configure(color: color, period: period, inViewport: inViewport)
    }

    static func dismantleNSView(_ view: BeamLayerView, coordinator: ()) {
        view.tearDown()
    }
}

final class BeamLayerView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private var configuredColor: NSColor?
    private var observers: [NSObjectProtocol] = []
    private var inViewport = false
    private var period: TimeInterval = 5.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.mask = maskLayer
        gradientLayer.speed = 0
        layer?.addSublayer(gradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeObservers()
        pause()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            observe(NSWindow.didChangeOcclusionStateNotification, object: window)
            observe(NSApplication.didBecomeActiveNotification, object: NSApp)
            observe(NSApplication.didResignActiveNotification, object: NSApp)
            observe(.NSProcessInfoPowerStateDidChange, object: nil)
        }
        updateAnimationState()
    }

    private func observe(_ name: Notification.Name, object: Any?) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAnimationState()
            }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func tearDown() {
        removeObservers()
        pause()
        gradientLayer.removeAllAnimations()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        maskLayer.frame = gradientLayer.bounds
        maskLayer.path = CGPath(ellipseIn: gradientLayer.bounds, transform: nil)
        CATransaction.commit()
        updateAnimationState()
    }

    func configure(color: NSColor, period: TimeInterval, inViewport: Bool) {
        self.inViewport = inViewport
        self.period = period.isFinite ? max(1, period) : 5.5
        if configuredColor != color {
            configuredColor = color
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradientLayer.colors = [
                color.withAlphaComponent(0.65).cgColor,
                color.withAlphaComponent(0.20).cgColor,
                color.withAlphaComponent(0).cgColor,
                color.withAlphaComponent(0).cgColor
            ]
            gradientLayer.locations = [0, 0.02, 0.26, 1]
            CATransaction.commit()
        }
        updateAnimationState()
    }

    private func updateAnimationState() {
        let shouldRun = RadarMotionPolicy.runsContinuousMotion(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            inViewport: inViewport,
            windowVisible: window?.occlusionState.contains(.visible) == true,
            applicationActive: NSApp.isActive
        )
        guard shouldRun else { pause(); return }
        if gradientLayer.speed == 0 {
            let pausedTime = gradientLayer.timeOffset
            gradientLayer.speed = 1
            gradientLayer.timeOffset = 0
            gradientLayer.beginTime = 0
            gradientLayer.beginTime = gradientLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        }
        // Establish the local clock before adding the first animation.
        ensureRotation(period: period)
    }

    private func pause() {
        guard gradientLayer.speed != 0 else { return }
        let currentTime = gradientLayer.convertTime(CACurrentMediaTime(), from: nil)
        gradientLayer.speed = 0
        gradientLayer.timeOffset = currentTime
    }

    private func ensureRotation(period: TimeInterval = 5.5) {
        guard gradientLayer.animation(forKey: "sweep") == nil else {
            return
        }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -2 * Double.pi
        rotation.beginTime = gradientLayer.convertTime(CACurrentMediaTime(), from: nil)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var color: Color {
        row.level == .quiet ? RadarTheme.brand : RadarStyle.color(for: row.level)
    }

    private var coreSize: CGFloat {
        row.level >= .hot ? 7 : 5.5
    }

    var body: some View {
        Button {
            session.focus(.family(row.id))
        } label: {
            ZStack {
                Circle()
                    .fill(color.opacity(row.level >= .hot ? 0.15 : 0.09))
                    .frame(width: coreSize + 8, height: coreSize + 8)
                Circle()
                    .fill(color.opacity(0.85))
                    .frame(width: coreSize, height: coreSize)
                Circle()
                    .strokeBorder(color.opacity(isHovering ? 0.85 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 26, height: 26)
                    .scaleEffect(isHovering || reduceMotion ? 1 : 0.8)
                    .animation(RadarMotion.response(reduceMotion), value: isHovering)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .familyRowActions(row: row, session: session)
        .help("\(row.title) — \(row.statusText): \(row.subtitle)\n\(row.metricText)")
        .accessibilityLabel("\(row.title), \(row.statusText), \(row.subtitle), \(row.metricText)")
    }
}
