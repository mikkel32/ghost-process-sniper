// The thinking-orbs 0.3.2 tuning path (dots, dotSize, opts) and the ink tint,
// checked against orbs-tuned-golden.json — frames and tint ramps produced by
// the web engine itself (resolvePreset → scaleCounts → scaleRadii → opts →
// MODE_FRAMES; inkColor), see the tuned-golden script.

import Foundation
import Testing
@testable import ThinkingOrbsKit

struct OrbTuningTests {
    struct Golden: Decodable {
        struct Case: Decodable {
            let state: String, size: Int, dots: Double, dotSize: Double, opts: [String: Double], t: Double
            let dotsOut: [[Double]], linesOut: [[Double]]
        }
        struct Tint: Decodable { let tint: [Double]; let w: Double; let dark: Bool; let rgb: [Double] }
        let cases: [Case]
        let tints: [Tint]
    }

    let golden: Golden = {
        let url = Bundle.module.url(forResource: "orbs-tuned-golden", withExtension: "json")!
        return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }()

    @Test func tunedFramesMatchTheWebEngine() throws {
        for c in golden.cases {
            let state = try #require(OrbState(rawValue: c.state))
            let size = try #require(OrbSize(rawValue: c.size))
            let preset = resolvePreset(state, size).tuned(dots: c.dots, dotSize: c.dotSize, opts: c.opts)
            let f = orbFrame(preset, size: Double(c.size), t: c.t)
            #expect(f.dots.count == c.dotsOut.count, "\(c.state)@\(c.size) dot count")
            #expect(f.lines.count == c.linesOut.count, "\(c.state)@\(c.size) line count")
            // Both sides are finalized: z-sorted far → near with a stable
            // tiebreak, so the arrays line up index by index.
            var worst = 0.0, firstBad: String?
            for (i, (d, w)) in zip(f.dots, c.dotsOut).enumerated() {
                let mine = [d.x, d.y, d.z, d.r, d.white, d.a]
                let err = zip(mine, w).map { abs($0 - $1) }.max() ?? 0
                worst = max(worst, err)
                if err > 1e-4, firstBad == nil { firstBad = "dot \(i): \(mine) vs \(w)" }
            }
            #expect(firstBad == nil, "\(c.state)@\(c.size): worst \(worst); \(firstBad ?? "")")
        }
    }

    @Test func tintRampMatchesInkColor() {
        for s in golden.tints {
            let tint = OrbTint(r: s.tint[0], g: s.tint[1], b: s.tint[2])
            let (r, g, b) = tint.ramp(s.w, dark: s.dark)
            #expect([r, g, b] == s.rgb, "tint \(s.tint) w \(s.w) dark \(s.dark)")
        }
    }

    @Test func tintParsesLikeTheWeb() {
        #expect(OrbTint("#7cd4ff") == .sky)
        #expect(OrbTint("#fff") == OrbTint(r: 255, g: 255, b: 255))
        #expect(OrbTint("rgba(255, 210, 143, 0.5)") == .amber)
        #expect(OrbTint("hotpink") == nil)
    }
}
