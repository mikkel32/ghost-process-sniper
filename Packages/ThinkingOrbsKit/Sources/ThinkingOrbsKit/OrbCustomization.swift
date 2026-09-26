// thinking-orbs 0.3.2 customisation: ink tint, dot density / size, raw
// engine options, and custom geometry — mirroring the web component's
// `color`, `dots`, `dotSize`, `opts` and `frame` props.

import Foundation

/// Raw engine draw options for a state's geometry (web `ModeOpts`), e.g.
/// `["ghostA": 0.2, "particles": 5]` for `.working`. Unknown keys are ignored.
public typealias OrbOptions = [String: Double]

/// Custom geometry (web `ModeFrame`): the orb's side in points, the engine
/// clock `t` (seconds × preset speed × `speed`) and the resolved options →
/// one finished frame. Build it with ``OrbToolkit``; keep it pure.
public typealias OrbFrameBuilder = @Sendable (_ size: Double, _ t: Double, _ opts: OrbOptions) -> OrbFrame

/// Ink tint (web `color`). The depth ramp stays on the tint: on dark
/// backgrounds it fades toward black with depth, on light toward white.
public struct OrbTint: Sendable, Equatable {
    /// 0…255 per channel.
    public var r: Double, g: Double, b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// `#rgb`, `#rrggbb` or `rgb()` / `rgba()` (alpha ignored), like the web;
    /// anything else is nil (the web then draws the stock greys).
    public init?(_ css: String) {
        let s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            var h = String(s.dropFirst())
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6, let n = UInt32(h, radix: 16) else { return nil }
            self.init(r: Double(n >> 16 & 255), g: Double(n >> 8 & 255), b: Double(n & 255))
            return
        }
        guard s.lowercased().hasPrefix("rgb"), let open = s.firstIndex(of: "(") else { return nil }
        let nums = s[s.index(after: open)...].split { $0 == "," || $0 == ")" || $0 == " " }.compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        self.init(r: nums[0], g: nums[1], b: nums[2])
    }

    /// The Studio swatches (pale inks meant for dark surfaces).
    public static let sky = OrbTint(r: 0x7C, g: 0xD4, b: 0xFF)
    public static let amber = OrbTint(r: 0xFF, g: 0xD2, b: 0x8F)
    public static let pink = OrbTint(r: 0xFF, g: 0x9E, b: 0xC9)
    public static let mint = OrbTint(r: 0x9F, g: 0xE8, b: 0xA8)

    /// Web `inkColor` ramp for ink value `w` (0…1), 0…255.
    func ramp(_ w: Double, dark: Bool) -> (Double, Double, Double) {
        func f(_ c: Double) -> Double { (dark ? c * (1 - w) : c + (255 - c) * w).rounded(.toNearestOrAwayFromZero) }
        return (f(r), f(g), f(b))
    }
}

public extension ResolvedPreset {
    /// The resolved draw options (what a custom ``OrbFrameBuilder`` receives).
    var options: OrbOptions { opts }

    /// Web order: `dots` scales every count knob, `dotSize` every radius (both
    /// floored at 0.1), then `opts` is merged over the result.
    func tuned(dots: Double = 1, dotSize: Double = 1, opts override: OrbOptions? = nil) -> ResolvedPreset {
        var o = opts
        if dots != 1 { o = scaleCounts(o, Swift.max(0.1, dots)) }
        if dotSize != 1 { o = scaleRadii(o, Swift.max(0.1, dotSize)) }
        if let override { o.merge(override) { $1 } }
        return ResolvedPreset(mode: mode, speed: speed, opts: o)
    }
}

/// The engine's frame toolkit (web `finalizeFrame`, `makeProj`,
/// `radiusScale`, `fibDir`, `hashD`, `vnoise`, `lerp`, `frac`,
/// `angleDelta`, `MODE_FRAMES`) for custom geometry.
public enum OrbToolkit {
    /// Drop invisible marks (alpha < 0.02), clamp radii to `rMin`, z-sort
    /// far → near. Return this from a custom builder.
    public static func finalize(dots: [Dot], lines: [Line] = [], rMin: Double = 0.3) -> OrbFrame {
        finalizeFrame(dots, lines, rMin: rMin)
    }

    /// Spin (`yaw`) + `tilt` + orthographic projection centred at (cx, cy):
    /// returns screen x, y and depth z for a point on the unit sphere × scale.
    public static func projector(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double)
        -> @Sendable (Double, Double, Double) -> (x: Double, y: Double, z: Double)
    {
        let p = Projector(yaw: yaw, tilt: tilt, cx: cx, cy: cy, scale: scale)
        return { x, y, z in let r = p(x, y, z); return (r.0, r.1, r.2) }
    }

    /// Dot radii were tuned for a 300 pt frame: `(size / 300)^pow`.
    public static func radiusScale(_ size: Double, pow: Double = 0.6) -> Double {
        ThinkingOrbsKit.radiusScale(size, pow: pow)
    }

    /// Fibonacci-sphere direction `i` of `n`.
    public static func fibDir(_ i: Int, _ n: Int) -> (x: Double, y: Double, z: Double) {
        let d = ThinkingOrbsKit.fibDir(i, n)
        return (d.0, d.1, d.2)
    }

    /// Deterministic hash in [0, 1).
    public static func hash(_ a: Double, _ b: Double) -> Double { hashD(a, b) }
    /// Smooth value noise in [0, 1).
    public static func noise(_ x: Double, _ y: Double) -> Double { vnoise(x, y) }
    public static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { ThinkingOrbsKit.lerp(a, b, f) }
    public static func frac(_ x: Double) -> Double { ThinkingOrbsKit.frac(x) }
    /// Shortest signed angle from `b` to `a`.
    public static func angleDelta(_ a: Double, _ b: Double) -> Double { ThinkingOrbsKit.angleDelta(a, b) }

    /// A state's stock geometry, e.g. to wrap or post-process it.
    public static func stockFrame(for state: OrbState) -> OrbFrameBuilder {
        let mode = state.mode
        return { size, t, opts in orbFrame(ResolvedPreset(mode: mode, speed: 1, opts: opts), size: size, t: t) }
    }
}
