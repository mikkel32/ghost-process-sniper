import SwiftUI
import ThinkingOrbsKit

/// A wait worth watching: the text says what is happening, and the orb
/// joins it only once the wait has lasted `orbDelay`, because an orb that
/// flashes for half a second reads as a glitch. The orb is decoration;
/// VoiceOver reads the text.
struct RadarWaitLabel: View {
    let text: String
    let orbDelay: Duration

    @State private var showsOrb: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String, orbDelay: Duration = .seconds(2)) {
        self.text = text
        self.orbDelay = orbDelay
        _showsOrb = State(initialValue: orbDelay <= .zero)
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsOrb {
                ThinkingOrb(state: .breathing, size: .px20)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            Text(text)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: showsOrb)
        .task {
            guard !showsOrb else { return }
            try? await Task.sleep(for: orbDelay)
            if !Task.isCancelled { showsOrb = true }
        }
    }
}
