// The reference's worked `frame:` examples, compiled against the PUBLIC API
// only (no @testable), so custom geometry is proven possible from an app.
import Foundation
import Testing
import ThinkingOrbsKit

/// A loxodrome winding pole to pole (hosted on `.weaving`).
let spiralFrame: OrbFrameBuilder = { size, t, o in
    let c = size / 2, R = c * 0.76
    let pt = OrbToolkit.projector(yaw: t * 0.4, tilt: 0.3, cx: c, cy: c, scale: 1)
    let rs = OrbToolkit.radiusScale(size, pow: o["rsPow"] ?? 0.6)
    var dots: [Dot] = []
    let ghostN = Int(o["ghostN"] ?? 150)
    for i in 0..<ghostN {
        let d = OrbToolkit.fibDir(i, ghostN)
        let p = pt(d.x * R, d.y * R, d.z * R)
        dots.append(Dot(x: p.x, y: p.y, z: p.z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * ((p.z / R + 1) / 2)))
    }
    let n = Int(o["strandN"] ?? 52) * 3
    let turns = o["turns"] ?? 3
    for i in 0..<n {
        let u = (OrbToolkit.frac(Double(i) / Double(n) + t * 0.045) * 2 - 1) * 0.96
        let ring = (1 - u * u).squareRoot()
        let a = u * .pi * turns * 2
        let p = pt(cos(a) * ring * R, u * R, sin(a) * ring * R)
        let depth = (p.z / R + 1) / 2
        dots.append(Dot(
            x: p.x, y: p.y, z: p.z,
            r: ((o["rBase"] ?? 1.2) + (o["rDepth"] ?? 1.8) * depth) * rs,
            white: 0.55 - 0.45 * depth,
            a: min(1, (1 - abs(u)) / 0.1) * (0.45 + 0.55 * depth)
        ))
    }
    return OrbToolkit.finalize(dots: dots, rMin: o["rMin"] ?? 0.3)
}

/// A dotted sphere beating "lub-dub" (hosted on `.listening`).
let heartbeatFrame: OrbFrameBuilder = { size, t, o in
    let c = size / 2
    let pt = OrbToolkit.projector(yaw: t * 0.18, tilt: 0.38, cx: c, cy: c, scale: 1)
    let rs = OrbToolkit.radiusScale(size, pow: o["rsPow"] ?? 0.6)
    let ph = OrbToolkit.frac(t / 3.6)
    let beat = exp(-pow(ph - 0.05, 2) / 0.002) + 0.6 * exp(-pow(ph - 0.22, 2) / 0.002)
    let R = c * 0.82 * (0.86 + 0.1 * beat)
    let rings = Int(o["rings"] ?? 15), lonDensity = o["lonDensity"] ?? 40
    var dots: [Dot] = []
    for ri in 0...rings {
        let lat = -Double.pi / 2 + Double(ri) / Double(rings) * .pi
        let lonCount = max(1, Int((abs(cos(lat)) * lonDensity).rounded()))
        for lj in 0..<lonCount {
            let lon = Double(lj) / Double(lonCount) * 2 * .pi
            let p = pt(cos(lat) * cos(lon) * R, sin(lat) * R, cos(lat) * sin(lon) * R)
            let depth = (p.z / R + 1) / 2
            dots.append(Dot(
                x: p.x, y: p.y, z: p.z,
                r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth) * (1 + 0.5 * beat) * rs,
                white: 0.66 - 0.56 * depth - 0.12 * beat
            ))
        }
    }
    return OrbToolkit.finalize(dots: dots, rMin: o["rMin"] ?? 0.3)
}

struct OrbCustomFrameTests {
    @Test func workedExamplesStayFiniteAndInside() {
        for (frame, state) in [(spiralFrame, OrbState.weaving), (heartbeatFrame, .listening)] {
            for size in OrbSize.allCases {
                let opts = resolvePreset(state, size).options
                for t in [0.7, 3.3, 1e5] {
                    let f = frame(Double(size.rawValue), t, opts)
                    #expect(!f.dots.isEmpty)
                    let s = Double(size.rawValue)
                    #expect(f.dots.allSatisfy { [$0.x, $0.y, $0.z, $0.r, $0.white].allSatisfy(\.isFinite) })
                    #expect(f.dots.allSatisfy { $0.x >= 0 && $0.x <= s && $0.y >= 0 && $0.y <= s })
                }
            }
        }
    }
}
