import AppKit
import GhostProcessSniperCore
import SwiftUI

enum RadarStyle {
    static func color(for level: GhostLevel) -> Color {
        switch level {
        case .quiet: .secondary
        case .watch: .orange
        case .hot: .red
        case .critical: critical
        }
    }

    static func icon(for level: GhostLevel) -> String {
        switch level {
        case .quiet: "checkmark.circle"
        case .watch: "eye"
        case .hot: "flame"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    /// Critical is the strongest red, not pink: pink read milder than Hot
    /// and belongs to the Incidents tool.
    static let critical = Color(nsColor: .systemRed)
}

enum RadarTheme {
    static let brand = Color(red: 0.16, green: 0.72, blue: 0.88)
    static let brandSecondary = Color(red: 0.38, green: 0.42, blue: 0.98)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let elevatedPanel = Color(nsColor: .underPageBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)

    static func accent(for level: GhostLevel) -> Color {
        switch level {
        case .quiet: brand
        case .watch: .orange
        case .hot: .red
        case .critical: RadarStyle.critical
        }
    }
}

private struct RadarSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let isRaised: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surfaced = content
            .background(shape.fill(isRaised ? RadarTheme.elevatedPanel : RadarTheme.panel))
            .overlay {
                shape.strokeBorder(RadarTheme.separator.opacity(0.72), lineWidth: 0.75)
            }
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(tint)
                    .frame(width: isRaised ? 52 : 32, height: 2)
                    .padding(.leading, 14)
                    .opacity(isRaised ? 0.9 : 0.5)
            }

        if isRaised {
            surfaced.shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        } else {
            surfaced
        }
    }
}

extension View {
    func radarSurface(
        tint: Color = RadarTheme.brand,
        cornerRadius: CGFloat = 16,
        raised: Bool = false
    ) -> some View {
        modifier(RadarSurfaceModifier(tint: tint, cornerRadius: cornerRadius, isRaised: raised))
    }
}
