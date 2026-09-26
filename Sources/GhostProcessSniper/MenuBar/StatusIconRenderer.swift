import AppKit
import GhostProcessSniperCore

/// Drawing-handler images redraw for every backing scale and appearance, so
/// the quiet template icon follows the menu bar and stays sharp. Severity is
/// carried by shape as well as colour: a filled centre from Watch, heavier
/// crosshairs at Hot, and a solid glowing disc at Critical.
@MainActor
enum StatusIconRenderer {
    private static var cache: [GhostLevel: NSImage] = [:]

    static func image(level: GhostLevel) -> NSImage {
        if let image = cache[level] {
            return image
        }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(level: level)
            return true
        }
        image.isTemplate = level == .quiet
        image.accessibilityDescription = level.label
        cache[level] = image
        return image
    }

    // Colours resolve here, at draw time, under the menu bar's appearance.
    nonisolated private static func draw(level: GhostLevel) {
        switch level {
        case .quiet:
            drawScope(color: .black, filledCentre: false, crosshairWidth: 1.2)
        case .watch:
            drawScope(color: .systemOrange, filledCentre: true, crosshairWidth: 1.2)
        case .hot:
            drawScope(color: .systemRed, filledCentre: true, crosshairWidth: 1.6)
        case .critical:
            drawCriticalDisc()
        }
    }

    nonisolated private static func drawScope(color: NSColor, filledCentre: Bool, crosshairWidth: CGFloat) {
        color.setStroke()
        color.setFill()

        let ring = NSBezierPath(ovalIn: NSRect(x: 3.2, y: 3.2, width: 11.6, height: 11.6))
        ring.lineWidth = 1.5
        ring.stroke()

        let centre = NSBezierPath(ovalIn: NSRect(x: 7.2, y: 7.2, width: 3.6, height: 3.6))
        if filledCentre {
            centre.fill()
        } else {
            centre.lineWidth = 1.2
            centre.stroke()
        }

        let crosshair = NSBezierPath()
        crosshair.lineWidth = crosshairWidth
        crosshair.move(to: NSPoint(x: 9, y: 1.8))
        crosshair.line(to: NSPoint(x: 9, y: 5))
        crosshair.move(to: NSPoint(x: 9, y: 13))
        crosshair.line(to: NSPoint(x: 9, y: 16.2))
        crosshair.move(to: NSPoint(x: 1.8, y: 9))
        crosshair.line(to: NSPoint(x: 5, y: 9))
        crosshair.move(to: NSPoint(x: 13, y: 9))
        crosshair.line(to: NSPoint(x: 16.2, y: 9))
        crosshair.stroke()
    }

    nonisolated private static func drawCriticalDisc() {
        let color = NSColor.systemRed
        let discRect = NSRect(x: 2.4, y: 2.4, width: 13.2, height: 13.2)

        // The glow is clipped to outside the disc so it cannot tint the
        // knocked-out ring.
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
        outside.append(NSBezierPath(ovalIn: discRect))
        outside.windingRule = .evenOdd
        outside.addClip()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = .zero
        shadow.set()
        color.setFill()
        NSBezierPath(ovalIn: discRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        // The scope ring is cut out of the disc by even-odd filling rather than
        // destination compositing, which would also erase the menu bar behind it
        // whenever AppKit draws the handler straight into its own context.
        let disc = NSBezierPath(ovalIn: discRect)
        disc.append(NSBezierPath(ovalIn: NSRect(x: 4.7, y: 4.7, width: 8.6, height: 8.6)))
        disc.append(NSBezierPath(ovalIn: NSRect(x: 6.1, y: 6.1, width: 5.8, height: 5.8)))
        disc.windingRule = .evenOdd
        color.setFill()
        disc.fill()
    }
}
