import SwiftUI

/// Hover and press feedback for the sidebar's row buttons.
struct RadarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(RadarTheme.brand.opacity(configuration.isPressed ? 0.15 : isHovering ? 0.07 : 0))
                        .animation(RadarMotion.response(reduceMotion), value: isHovering)
                        .animation(RadarMotion.response(reduceMotion), value: configuration.isPressed)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(RadarTheme.brand.opacity(configuration.isPressed ? 0.4 : isHovering ? 0.22 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                        .animation(RadarMotion.response(reduceMotion), value: isHovering)
                }
                .onHover { isHovering = $0 }
        }
    }
}
