import SwiftUI

enum RadarMotion {
    static func response(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12)
    }
    static func reading(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.32)
    }

    /// Keeps a scanning indicator up long enough to be seen after a fast refresh.
    static func holdPerceptibly(since started: Date, minimum: TimeInterval = 0.7) async {
        let remaining = minimum - Date().timeIntervalSince(started)
        guard remaining > 0 else {
            return
        }
        try? await Task.sleep(for: .seconds(remaining))
    }
}

/// Applied to a handful of dashboard sections, never to each process row.
private struct RadarEntrance: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 7)
            .onAppear {
                guard !appeared else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.38).delay(delay)) { appeared = true }
            }
    }
}

extension View {
    func radarEntrance(delay: Double = 0) -> some View { modifier(RadarEntrance(delay: delay)) }
}

/// Animate only a text value, not its surrounding live layout or hit targets.
struct RadarReading: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(RadarMotion.reading(reduceMotion), value: text)
    }
}

struct RadarCardButtonStyle: ButtonStyle {
    var tint: Color = RadarTheme.brand
    func makeBody(configuration: Configuration) -> some View { CardBody(configuration: configuration, tint: tint) }

    private struct CardBody: View {
        let configuration: ButtonStyle.Configuration
        let tint: Color
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(tint.opacity(hovered && isEnabled ? 0.55 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                        .animation(RadarMotion.response(reduceMotion), value: hovered)
                }
                .animation(RadarMotion.response(reduceMotion)) { content in
                    content
                        .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.985 : 1)
                        .offset(y: hovered && isEnabled && !configuration.isPressed && !reduceMotion ? -2 : 0)
                }
                .onHover { hovered = $0 }
        }
    }
}

/// The selection surface moves; table contents do not animate or swap identities.
struct RadarSelectionSurface: View {
    let selected: Bool
    let namespace: Namespace.ID
    let key: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 10)
                    .fill(RadarTheme.brand.opacity(0.16).gradient)
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(RadarTheme.brand.opacity(0.24), lineWidth: 1) }
                    .matchedGeometryEffect(id: key, in: namespace)
            }
        }
        .animation(RadarMotion.response(reduceMotion), value: selected)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
