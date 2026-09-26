import AppKit
import SwiftUI

/// Fetch each bundle icon once, with a bounded cache shared by rows and the inspector.
struct ThermalAppIcon: View {
    let path: String?
    var isSystemProcess = false
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: isSystemProcess ? "gearshape.2.fill" : "app.fill")
                    .resizable().scaledToFit().padding(7)
                    .foregroundStyle(RadarTheme.brand)
            }
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
        .task(id: path) {
            icon = nil
            guard let path else { return }
            icon = ThermalAppIconCache.image(for: path)
        }
    }
}

@MainActor
private enum ThermalAppIconCache {
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        return cache
    }()

    static func image(for path: String) -> NSImage {
        if let image = cache.object(forKey: path as NSString) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
