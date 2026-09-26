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

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = .zero
        shadow.set()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2.4, y: 2.4, width: 13.2, height: 13.2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Knock the scope ring out of the disc so it still reads as the same mark.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 5.4, y: 5.4, width: 7.2, height: 7.2))
        ring.lineWidth = 1.4
        ring.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
