import AppKit
import GhostProcessSniperCore
import QuartzCore
import SwiftUI

/// The sweep and its phosphor: a beam turning once per period and, on every
/// blip, a glow that flares as the beam crosses it and fades behind it. Each
/// is one committed Core Animation on the render server; SwiftUI draws no
/// frames for it. It pauses when off screen, inactive or in Low Power Mode.
struct RadarSweepLayer: NSViewRepresentable {
    struct Glow: Equatable {
        let id: String
        let x: Double
        let y: Double
        let bearing: Double
        let diameter: Double
        let color: NSColor
    }

    let centerX: Double
    let centerY: Double
    let radius: Double
    let glows: [Glow]
    let beamColor: NSColor
    let inViewport: Bool

    static let period: TimeInterval = 4

    func makeNSView(context: Context) -> RadarSweepView {
        RadarSweepView()
    }

    func updateNSView(_ view: RadarSweepView, context: Context) {
        view.configure(centerX: centerX, centerY: centerY, radius: radius, glows: glows, beamColor: beamColor,
                       inViewport: inViewport)
    }

    static func dismantleNSView(_ view: RadarSweepView, coordinator: ()) {
        view.tearDown()
    }
}

final class RadarSweepView: NSView {
    /// Every sweep animation keeps its time here, so one pause stops all of
    /// them in step and resuming does not snap the beam back. Local time
    /// starts at 1 s: an animation's beginTime of 0 would mean "now".
    private let clock = CALayer()
    private let beam = CAGradientLayer()
    private let beamMask = CAShapeLayer()
    private var glowLayers: [String: CAGradientLayer] = [:]
    private var glowBearings: [String: Double] = [:]
    private var glowColors: [String: NSColor] = [:]
    private var beamColor: NSColor?
    private var observers: [NSObjectProtocol] = []
    private var inViewport = false
    private static let epoch: CFTimeInterval = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clock.speed = 0
        clock.timeOffset = Self.epoch
        clock.isHidden = true
        beam.type = .conic
        beam.startPoint = CGPoint(x: 0.5, y: 0.5)
        beam.endPoint = CGPoint(x: 1, y: 0.5)
        beam.locations = [0, 0.02, 0.24, 1]
        beam.mask = beamMask
        clock.addSublayer(beam)
        layer?.addSublayer(clock)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
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
        updateRunning()
    }

    private func observe(_ name: Notification.Name, object: Any?) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateRunning() }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func tearDown() {
        removeObservers()
        pause()
        beam.removeAllAnimations()
        glowLayers.values.forEach { $0.removeAllAnimations() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.frame = bounds
        CATransaction.commit()
    }

    func configure(centerX: Double, centerY: Double, radius: Double, glows: [RadarSweepLayer.Glow],
                   beamColor: NSColor, inViewport: Bool) {
        self.inViewport = inViewport && radius > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Layer space is bottom-up; the scene is top-down.
        let height = bounds.height
        let circle = CGRect(x: centerX - radius, y: height - centerY - radius, width: radius * 2, height: radius * 2)
        if beam.frame != circle {
            beam.frame = circle
            beamMask.frame = beam.bounds
            beamMask.path = CGPath(ellipseIn: beam.bounds, transform: nil)
        }
        if self.beamColor != beamColor {
            self.beamColor = beamColor
            beam.colors = [0.42, 0.14, 0, 0].map { beamColor.withAlphaComponent($0).cgColor }
        }
        var present = Set<String>()
        for glow in glows {
            present.insert(glow.id)
            let layer = glowLayers[glow.id] ?? makeGlow(id: glow.id)
            let size = max(14, glow.diameter * 3.4)
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.position = CGPoint(x: glow.x, y: height - glow.y)
            if glowColors[glow.id] != glow.color {
                glowColors[glow.id] = glow.color
                layer.colors = [0.9, 0.38, 0].map { glow.color.withAlphaComponent($0).cgColor }
            }
            if let bearing = glowBearings[glow.id], abs(bearing - glow.bearing) < 0.004 { continue }
            glowBearings[glow.id] = glow.bearing
            layer.removeAnimation(forKey: "phosphor")
            layer.add(Self.phosphor(bearing: glow.bearing), forKey: "phosphor")
        }
        for (id, layer) in glowLayers where !present.contains(id) {
            layer.removeFromSuperlayer()
            glowLayers[id] = nil
            glowBearings[id] = nil
            glowColors[id] = nil
        }
        CATransaction.commit()
        updateRunning()
    }

    private func makeGlow(id: String) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        layer.locations = [0, 0.3, 1]
        layer.opacity = 0
        clock.insertSublayer(layer, below: beam)
        glowLayers[id] = layer
        return layer
    }

    /// Bright the moment the beam's leading edge reaches this bearing, then
    /// fading over two fifths of a turn. The beam starts at 3 o'clock and
    /// turns clockwise, as screen bearings are measured.
    static func phosphor(bearing: Double) -> CAKeyframeAnimation {
        let period = RadarSweepLayer.period
        let turn = 2 * Double.pi
        let crossing = (bearing.truncatingRemainder(dividingBy: turn) + turn).truncatingRemainder(dividingBy: turn) / turn * period
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.95, 0.6, 0, 0]
        animation.keyTimes = [0, 0.06, 0.4, 1]
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = epoch
        animation.timeOffset = period - crossing
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func updateRunning() {
        let shouldRun = RadarMotionPolicy.runsContinuousMotion(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            inViewport: inViewport,
            windowVisible: window?.occlusionState.contains(.visible) == true,
            applicationActive: NSApp.isActive
        )
        guard shouldRun else {
            pause()
            return
        }
        if clock.speed == 0 {
            let pausedTime = clock.timeOffset
            clock.speed = 1
            clock.timeOffset = 0
            clock.beginTime = 0
            clock.beginTime = clock.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        }
        clock.isHidden = false
        if beam.animation(forKey: "sweep") == nil {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = -2 * Double.pi
            rotation.beginTime = Self.epoch
            rotation.duration = RadarSweepLayer.period
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = false
            beam.add(rotation, forKey: "sweep")
        }
    }

    /// A paused sweep is hidden: a frozen beam and half-faded glows would
    /// read as data.
    private func pause() {
        clock.isHidden = true
        guard clock.speed != 0 else { return }
        let current = clock.convertTime(CACurrentMediaTime(), from: nil)
        clock.speed = 0
        clock.timeOffset = current
    }
}
