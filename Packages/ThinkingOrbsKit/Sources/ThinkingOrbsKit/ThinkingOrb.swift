// The SwiftUI ThinkingOrb.
//
// TimelineView(.animation) drives the clock and Canvas does the drawing —
// no timers, no Metal, no CADisplayLink to tear down. SwiftUI stops
// servicing a TimelineView that is off-screen, which is the equivalent of
// the web build's IntersectionObserver pause and comes for free.

import SwiftUI

/// Theme mode. `.auto` follows the environment's colour scheme.
public enum OrbTheme: Sendable {
    case auto, dark, light
}

@available(iOS 15.0, macOS 12.0, *)
public struct ThinkingOrb: View {
    private let state: OrbState
    private let size: OrbSize
    private let theme: OrbTheme
    private let speed: Double
    private let paused: Bool
    private let displaySize: Double?
    private let tint: OrbTint?
    private let dots: Double
    private let dotSize: Double
    private let opts: OrbOptions?
    private let frameBuilder: OrbFrameBuilder?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // ImageRenderer never advances a TimelineView, so snapshot.sh injects a
    // fixed instant here to capture a deterministic frame.
    @Environment(\.orbFrozenTime) private var frozenTime

    /// - Parameters:
    ///   - state: The animation itself (what the agent is doing).
    ///   - size: A tuned preset: `.px64` standalone, `.px32` compact avatar,
    ///     `.px20` inline with text.
    ///   - speed: Multiplier on the preset's speed (Studio 0.25…3); floored at 0.
    ///   - paused: Holds the current frame; resuming jumps to the shared clock.
    ///   - color: Ink tint (web `color`); nil draws the stock greys.
    ///   - dots: Density multiplier on every count knob (0.4…2).
    ///   - dotSize: Radius multiplier for every dot (0.5…2).
    ///   - opts: Raw engine options merged over the preset (web `opts`).
    ///   - frame: Custom geometry replacing the state's (web `frame`); the
    ///     painter, theme, tint, pause and reduced motion stay the kit's.
    ///   - displaySize: Draws the preset's geometry at another point size,
    ///     scaled inside the Canvas so it stays vector-crisp (RN port prop).
    public init(
        state: OrbState = .working,
        size: OrbSize = .px64,
        theme: OrbTheme = .auto,
        speed: Double = 1,
        paused: Bool = false,
        color: OrbTint? = nil,
        dots: Double = 1,
        dotSize: Double = 1,
        opts: OrbOptions? = nil,
        frame: OrbFrameBuilder? = nil,
        displaySize: Double? = nil
    ) {
        self.state = state
        self.size = size
        self.theme = theme
        self.speed = speed
        self.paused = paused
        self.tint = color
        self.dots = dots
        self.dotSize = dotSize
        self.opts = opts
        self.frameBuilder = frame
        self.displaySize = displaySize
    }

    private var isDark: Bool {
        switch theme {
        case .dark: return true
        case .light: return false
        case .auto: return colorScheme == .dark
        }
    }

    public var body: some View {
        let preset = resolvePreset(state, size).tuned(dots: dots, dotSize: dotSize, opts: opts)
        // Negative speed is unsupported (the web's `shaping` throws on a
        // negative clock; here it would index before the shape cycle).
        let effSpeed = preset.speed * Swift.max(0, speed)
        let side = displaySize ?? size.value

        Group {
            if let frozenTime {
                // Raw engine time, NOT scaled by speed: the golden vectors and
                // the web parity harness both evaluate the engine at this t
                // directly, so applying the preset speed here would compare
                // two different instants and report a false mismatch.
                canvas(preset: preset, t: frozenTime)
            } else if reduceMotion {
                // One static, deterministic frame at the web's reduced-motion
                // instant: `frame(0.6)` — raw engine time, not scaled by speed.
                canvas(preset: preset, t: OrbSpec.reducedMotionT)
            } else {
                // A paused schedule stops producing dates, so the orb holds the
                // frame it was showing — the web's `paused` ("freezes on the
                // current frame"); resuming rejoins the shared clock.
                TimelineView(.animation(paused: paused)) { timeline in
                    // One shared clock, so several orbs on screen stay in
                    // phase exactly as they do on the web.
                    let t = timeline.date.timeIntervalSinceReferenceDate * effSpeed
                    canvas(preset: preset, t: t)
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(state.label)
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func canvas(preset: ResolvedPreset, t: Double) -> some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            var context = context
            let zoom = (displaySize ?? size.value) / size.value
            if zoom != 1 { context.scaleBy(x: zoom, y: zoom) }
            let frame = frameBuilder?(size.value, t, preset.options) ?? orbFrame(preset, size: size.value, t: t)
            // lines first, so nodes sit on top of their edges
            for l in frame.lines {
                var path = Path()
                path.move(to: CGPoint(x: l.x1, y: l.y1))
                path.addLine(to: CGPoint(x: l.x2, y: l.y2))
                context.stroke(
                    path,
                    with: .color(ink(l.white, l.a)),
                    lineWidth: l.w
                )
            }
            // dots are already z-sorted into draw order by the engine
            for d in frame.dots {
                let rect = CGRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(ink(d.white, d.a)))
            }
        }
    }

    /// Quantise to 8-bit exactly as the canvas painter does, so the platforms
    /// land on identical greys rather than merely close ones.
    private func ink(_ white: Double, _ alpha: Double) -> Color {
        let w = Swift.min(1, Swift.max(0, white))
        if let tint {
            let (r, g, b) = tint.ramp(w, dark: isDark)
            return Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: alpha)
        }
        let g = ((isDark ? 1 - w : w) * 255).rounded(.toNearestOrAwayFromZero) / 255
        return Color(.sRGB, red: g, green: g, blue: g, opacity: alpha)
    }
}

// MARK: - Frozen time (snapshot testing)

private struct OrbFrozenTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// Pins the animation to a fixed instant. Used by the snapshot harness;
    /// `ImageRenderer` does not fire `onAppear` or advance `TimelineView`,
    /// so without this every capture would render the same t=0 frame.
    var orbFrozenTime: Double? {
        get { self[OrbFrozenTimeKey.self] }
        set { self[OrbFrozenTimeKey.self] = newValue }
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension View {
    /// Freeze every ThinkingOrb below this view at `t` seconds.
    public func orbFrozenTime(_ t: Double?) -> some View {
        environment(\.orbFrozenTime, t)
    }
}
