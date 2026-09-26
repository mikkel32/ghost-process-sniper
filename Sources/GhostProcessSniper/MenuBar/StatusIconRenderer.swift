import AppKit
import GhostProcessSniperCore

@MainActor
enum StatusIconRenderer {
    private static var cache: [GhostLevel: NSImage] = [:]

    static func image(level: GhostLevel) -> NSImage {
        if let image = cache[level] {
            return image
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let color: NSColor = switch level {
        case .quiet:
            .secondaryLabelColor
        case .watch:
            .systemOrange
        case .hot, .critical:
            .systemRed
        }

        if level != .quiet {
            let shadow = NSShadow()
            shadow.shadowColor = color.withAlphaComponent(0.65)
            shadow.shadowBlurRadius = level == .critical ? 6 : 4
            shadow.shadowOffset = .zero
            shadow.set()
        }

        color.setStroke()
        color.withAlphaComponent(level == .quiet ? 0.78 : 1).setStroke()

        let ring = NSBezierPath(ovalIn: NSRect(x: 3.2, y: 3.2, width: 11.6, height: 11.6))
        ring.lineWidth = 1.5
        ring.stroke()

        let inner = NSBezierPath(ovalIn: NSRect(x: 7.2, y: 7.2, width: 3.6, height: 3.6))
        inner.lineWidth = 1.2
        inner.stroke()

        let crosshair = NSBezierPath()
        crosshair.lineWidth = 1.2
        crosshair.move(to: NSPoint(x: 9, y: 1.8))
        crosshair.line(to: NSPoint(x: 9, y: 5))
        crosshair.move(to: NSPoint(x: 9, y: 13))
        crosshair.line(to: NSPoint(x: 9, y: 16.2))
        crosshair.move(to: NSPoint(x: 1.8, y: 9))
        crosshair.line(to: NSPoint(x: 5, y: 9))
        crosshair.move(to: NSPoint(x: 13, y: 9))
        crosshair.line(to: NSPoint(x: 16.2, y: 9))
        crosshair.stroke()

        image.unlockFocus()
        image.isTemplate = false
        cache[level] = image
        return image
    }
}
