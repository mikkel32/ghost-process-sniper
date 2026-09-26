#!/usr/bin/env swift
// Renders the app icon, the DMG window background, and the README icon from code so
// release artwork is reproducible. Run from the repository root:
//
//     swift Packaging/render-artwork.swift
//
// Outputs: Packaging/AppIcon.icns, Packaging/dmg-background.tiff, Docs/Assets/icon.png

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette (matches RadarTheme.brand / brandSecondary)

let brand = CGColor(srgbRed: 0.16, green: 0.72, blue: 0.88, alpha: 1)
let brandSecondary = CGColor(srgbRed: 0.38, green: 0.42, blue: 0.98, alpha: 1)
let deepTop = CGColor(srgbRed: 0.075, green: 0.125, blue: 0.215, alpha: 1)
let deepBottom = CGColor(srgbRed: 0.020, green: 0.035, blue: 0.075, alpha: 1)
let ghostTop = CGColor(srgbRed: 0.96, green: 0.99, blue: 1.0, alpha: 1)
let ghostBottom = CGColor(srgbRed: 0.62, green: 0.90, blue: 0.97, alpha: 1)
let eyeColor = CGColor(srgbRed: 0.03, green: 0.06, blue: 0.13, alpha: 1)
let warn = CGColor(srgbRed: 1.0, green: 0.62, blue: 0.20, alpha: 1)
let hot = CGColor(srgbRed: 1.0, green: 0.33, blue: 0.36, alpha: 1)

func withAlpha(_ color: CGColor, _ alpha: CGFloat) -> CGColor {
    color.copy(alpha: alpha) ?? color
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func bitmap(width: Int, height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render", code: 1)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

// MARK: - Shapes

/// Superellipse approximating the macOS continuous-corner icon plate.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for index in 0...steps {
        let t = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = c.x + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = c.y + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Classic ghost silhouette: domed head, straight sides, scalloped hem. y-up coordinates.
func ghostPath(center: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
    let r = width / 2
    let headY = center.y + height / 2 - r
    let hemY = center.y - height / 2
    let scallop = height * 0.12
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x - r, y: headY))
    path.addArc(center: CGPoint(x: center.x, y: headY), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: center.x + r, y: hemY + scallop))
    let third = r * 2 / 3
    var x = center.x + r
    for _ in 0..<3 {
        let next = x - third
        path.addQuadCurve(to: CGPoint(x: next, y: hemY + scallop),
                          control: CGPoint(x: (x + next) / 2, y: hemY - scallop))
        x = next
    }
    path.closeSubpath()
    return path
}

// MARK: - Radar scope

struct Scope {
    var center: CGPoint
    var radius: CGFloat
    var scale: CGFloat // 1.0 == the 1024-pt icon
}

func drawScope(_ context: CGContext, _ scope: Scope, sweepLead: CGFloat = 38, sweepTrail: CGFloat = 88,
               ringAlpha: CGFloat = 1, drawTicks: Bool = true) {
    let c = scope.center, R = scope.radius, s = scope.scale

    // Soft glow pooled in the middle of the scope.
    context.saveGState()
    let glow = linearGradient([withAlpha(brand, 0.30 * ringAlpha), withAlpha(brand, 0)])
    context.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: R * 1.05, options: [])
    context.restoreGState()

    // Sweep beam: thin slices so the fade is exact regardless of conic-gradient orientation.
    context.saveGState()
    let slices = 140
    for index in 0..<slices {
        let f0 = CGFloat(index) / CGFloat(slices)
        let f1 = CGFloat(index + 1) / CGFloat(slices)
        let a0 = (sweepLead + sweepTrail * f0) * .pi / 180
        let a1 = (sweepLead + sweepTrail * f1) * .pi / 180
        let wedge = CGMutablePath()
        wedge.move(to: c)
        wedge.addArc(center: c, radius: R, startAngle: a0, endAngle: a1 + 0.002, clockwise: false)
        wedge.closeSubpath()
        let alpha = 0.42 * pow(1 - f0, 2.2) * ringAlpha
        context.addPath(wedge)
        context.setFillColor(withAlpha(brand, alpha))
        context.fillPath()
    }
    // Leading edge.
    let lead = sweepLead * .pi / 180
    context.setShadow(offset: .zero, blur: 18 * s, color: withAlpha(brand, 0.9 * ringAlpha))
    context.setStrokeColor(withAlpha(CGColor(srgbRed: 0.75, green: 0.96, blue: 1, alpha: 1), 0.9 * ringAlpha))
    context.setLineWidth(5 * s)
    context.setLineCap(.round)
    context.move(to: c)
    context.addLine(to: CGPoint(x: c.x + cos(lead) * R, y: c.y + sin(lead) * R))
    context.strokePath()
    context.restoreGState()

    // Range rings.
    context.saveGState()
    for (fraction, alpha, width) in [(0.36, 0.22, 4.0), (0.68, 0.26, 4.0)] as [(CGFloat, CGFloat, CGFloat)] {
        let r = R * fraction
        context.setStrokeColor(withAlpha(brand, alpha * ringAlpha))
        context.setLineWidth(width * s)
        context.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    context.setShadow(offset: .zero, blur: 14 * s, color: withAlpha(brand, 0.55 * ringAlpha))
    context.setStrokeColor(withAlpha(brand, 0.85 * ringAlpha))
    context.setLineWidth(9 * s)
    context.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    context.restoreGState()

    // Bezel ticks.
    if drawTicks {
        context.saveGState()
        for index in 0..<72 {
            let angle = CGFloat(index) / 72 * 2 * .pi
            let major = index % 6 == 0
            let inner = R + (major ? 16 : 20) * s
            let outer = R + 32 * s
            context.move(to: CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
            context.addLine(to: CGPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
            context.setStrokeColor(withAlpha(brand, (major ? 0.7 : 0.3) * ringAlpha))
            context.setLineWidth((major ? 5 : 3) * s)
            context.strokePath()
        }
        context.restoreGState()
    }

    // Reticle: crosshair arms that stop short of the target.
    context.saveGState()
    context.setStrokeColor(withAlpha(brand, 0.55 * ringAlpha))
    context.setLineWidth(5 * s)
    context.setLineCap(.round)
    let gapInner = R * 0.52, gapOuter = R * 0.96
    for angle in [0, 90, 180, 270] as [CGFloat] {
        let a = angle * .pi / 180
        context.move(to: CGPoint(x: c.x + cos(a) * gapInner, y: c.y + sin(a) * gapInner))
        context.addLine(to: CGPoint(x: c.x + cos(a) * gapOuter, y: c.y + sin(a) * gapOuter))
    }
    context.strokePath()
    context.restoreGState()
}

func drawBlip(_ context: CGContext, at point: CGPoint, radius: CGFloat, color: CGColor) {
    context.saveGState()
    context.setShadow(offset: .zero, blur: radius * 2.4, color: color)
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    context.restoreGState()
}

func drawGhost(_ context: CGContext, center: CGPoint, width: CGFloat, height: CGFloat, scale s: CGFloat) {
    let body = ghostPath(center: center, width: width, height: height)

    // Outer glow.
    context.saveGState()
    context.setShadow(offset: .zero, blur: 46 * s, color: withAlpha(brand, 0.95))
    context.addPath(body)
    context.setFillColor(ghostBottom)
    context.fillPath()
    context.restoreGState()

    // Body gradient.
    context.saveGState()
    context.addPath(body)
    context.clip()
    let fill = linearGradient([ghostTop, ghostBottom])
    context.drawLinearGradient(fill, start: CGPoint(x: center.x, y: center.y + height / 2),
                               end: CGPoint(x: center.x, y: center.y - height / 2), options: [])
    // A cool indigo tint at the hem gives the body some volume.
    let hem = linearGradient([withAlpha(brandSecondary, 0), withAlpha(brandSecondary, 0.28)])
    context.drawLinearGradient(hem, start: CGPoint(x: center.x, y: center.y),
                               end: CGPoint(x: center.x, y: center.y - height / 2), options: [])
    context.restoreGState()

    // Eyes.
    let r = width / 2
    let eyeY = center.y + height / 2 - r * 1.02
    let eyeW = r * 0.30, eyeH = r * 0.42
    context.setFillColor(eyeColor)
    for dx in [-r * 0.36, r * 0.36] {
        context.fillEllipse(in: CGRect(x: center.x + dx - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: eyeH))
    }
    // Eye glints.
    context.setFillColor(withAlpha(ghostTop, 0.9))
    for dx in [-r * 0.36, r * 0.36] {
        let g = eyeW * 0.34
        context.fillEllipse(in: CGRect(x: center.x + dx - eyeW * 0.12, y: eyeY + eyeH * 0.08, width: g, height: g))
    }
}

// MARK: - App icon

func renderIcon(size: Int) -> CGImage {
    let context = bitmap(width: size, height: size)
    let s = CGFloat(size) / 1024
    context.scaleBy(x: s, y: s)

    // Plate: 824-pt artwork inside the 1024 canvas, per the macOS icon grid.
    let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let plate = squircle(in: plateRect)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: withAlpha(CGColor.black, 0.45))
    context.addPath(plate)
    context.setFillColor(deepBottom)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(plate)
    context.clip()
    context.drawLinearGradient(linearGradient([deepTop, deepBottom]),
                               start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Indigo bloom in the lower-left corner.
    context.drawRadialGradient(linearGradient([withAlpha(brandSecondary, 0.30), withAlpha(brandSecondary, 0)]),
                               startCenter: CGPoint(x: 230, y: 210), startRadius: 0,
                               endCenter: CGPoint(x: 230, y: 210), endRadius: 520, options: [])

    let scope = Scope(center: CGPoint(x: 512, y: 512), radius: 318, scale: 1)
    drawScope(context, scope)

    drawBlip(context, at: CGPoint(x: 512 + cos(3.75) * 318 * 0.68, y: 512 + sin(3.75) * 318 * 0.68),
             radius: 15, color: warn)
    drawBlip(context, at: CGPoint(x: 512 + cos(5.35) * 318 * 0.86, y: 512 + sin(5.35) * 318 * 0.86),
             radius: 11, color: hot)
    drawBlip(context, at: CGPoint(x: 512 + cos(2.35) * 318 * 0.88, y: 512 + sin(2.35) * 318 * 0.88),
             radius: 9, color: withAlpha(brand, 0.95))

    drawGhost(context, center: CGPoint(x: 512, y: 506), width: 236, height: 282, scale: 1)

    // Glassy top highlight and a hairline edge.
    context.drawLinearGradient(linearGradient([withAlpha(CGColor.white, 0.10), withAlpha(CGColor.white, 0)]),
                               start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    context.restoreGState()

    context.saveGState()
    context.addPath(squircle(in: plateRect.insetBy(dx: 1.5, dy: 1.5)))
    context.setStrokeColor(withAlpha(CGColor.white, 0.16))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    return context.makeImage()!
}

// MARK: - DMG background

// Window content is 660 x 420 pt. Finder places the icons (centers, top-left origin) at
// app (170, 205) and Applications (490, 205); see Scripts/lib/dmg_layout.applescript.
let dmgSize = CGSize(width: 660, height: 420)
let appIconCenter = CGPoint(x: 170, y: 205)
let applicationsIconCenter = CGPoint(x: 490, y: 205)

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: kern
    ])
}

func renderBackground(scale: CGFloat) -> CGImage {
    let width = Int(dmgSize.width * scale), height = Int(dmgSize.height * scale)
    let context = bitmap(width: width, height: height)
    context.scaleBy(x: scale, y: scale)
    let H = dmgSize.height
    func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }

    context.drawLinearGradient(linearGradient([deepTop, deepBottom]),
                               start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    context.drawRadialGradient(linearGradient([withAlpha(brandSecondary, 0.22), withAlpha(brandSecondary, 0)]),
                               startCenter: CGPoint(x: 80, y: 40), startRadius: 0,
                               endCenter: CGPoint(x: 80, y: 40), endRadius: 420, options: [])

    // Faint scope watermark behind the Applications drop target.
    context.saveGState()
    context.setAlpha(0.22)
    drawScope(context, Scope(center: flip(applicationsIconCenter), radius: 92, scale: 0.3),
              sweepLead: 62, sweepTrail: 80, ringAlpha: 0.9, drawTicks: false)
    context.restoreGState()

    // Arrow from the app to Applications.
    context.saveGState()
    let arrowY = H - appIconCenter.y
    let start = CGPoint(x: appIconCenter.x + 92, y: arrowY)
    let end = CGPoint(x: applicationsIconCenter.x - 96, y: arrowY)
    context.setLineCap(.round)
    context.setLineWidth(3)
    context.setLineDash(phase: 0, lengths: [2, 9])
    context.setStrokeColor(withAlpha(brand, 0.85))
    context.move(to: start)
    context.addLine(to: CGPoint(x: end.x - 8, y: end.y))
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])
    context.setLineWidth(3.5)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: end.x - 14, y: end.y + 11))
    context.addLine(to: end)
    context.addLine(to: CGPoint(x: end.x - 14, y: end.y - 11))
    context.strokePath()
    context.restoreGState()

    // Neutral label plates keep Finder's label text legible in both Light and Dark Mode.
    context.saveGState()
    for center in [appIconCenter, applicationsIconCenter] {
        // Finder draws 13-pt labels centered about 83 pt below a 128-pt icon's center.
        let plate = CGRect(x: center.x - 84, y: H - (center.y + 96), width: 168, height: 26)
        context.addPath(CGPath(roundedRect: plate, cornerWidth: 13, cornerHeight: 13, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0.50, green: 0.55, blue: 0.62, alpha: 0.78))
        context.fillPath()
    }
    context.restoreGState()

    // Copy.
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let title = text("Ghost Process Sniper", size: 22, weight: .semibold, color: .white, kern: 0.2)
    let subtitle = text("Drag the app into Applications to install", size: 13, weight: .regular,
                        color: NSColor(white: 1, alpha: 0.72))
    let hint = text("First launch: if macOS blocks the app, open System Settings › Privacy & Security and choose Open Anyway.",
                    size: 10.5, weight: .regular, color: NSColor(white: 1, alpha: 0.55))
    for (string, y) in [(title, H - 56), (subtitle, H - 80), (hint, 30)] as [(NSAttributedString, CGFloat)] {
        let bounds = string.size()
        string.draw(at: CGPoint(x: (dmgSize.width - bounds.width) / 2, y: y - bounds.height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()

    return context.makeImage()!
}

// MARK: - Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let packaging = root.appendingPathComponent("Packaging")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gps-artwork-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "render", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"])
    }
}

for points in [16, 32, 128, 256, 512] {
    try writePNG(renderIcon(size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(renderIcon(size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", packaging.appendingPathComponent("AppIcon.icns").path])
try writePNG(renderIcon(size: 512), to: root.appendingPathComponent("Docs/Assets/icon.png"))

let background1x = work.appendingPathComponent("background.png")
let background2x = work.appendingPathComponent("background@2x.png")
try writePNG(renderBackground(scale: 1), to: background1x)
try writePNG(renderBackground(scale: 2), to: background2x)
try run("/usr/bin/tiffutil", ["-cathidpicheck", background1x.path, background2x.path,
                              "-out", packaging.appendingPathComponent("dmg-background.tiff").path])

print("Rendered Packaging/AppIcon.icns, Packaging/dmg-background.tiff, Docs/Assets/icon.png")
