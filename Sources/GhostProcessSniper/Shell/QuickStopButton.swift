import GhostProcessSniperCore
import SwiftUI

/// The visible Quick Stop. Red only when the stop is recommended; callers
/// hide it when nothing in the family is the user's to stop. It opens the
/// preview sheet, never stops directly.
struct QuickStopButton: View {
    let action: QuickStopAction
    var usesShortTitle = true
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            Label(usesShortTitle ? action.shortTitle : action.title, systemImage: action.systemImage)
        }
        .buttonStyle(.bordered)
        .tint(action.emphasis == .recommended ? Color.red : nil)
        .help(helpText)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.detail ?? "Opens a preview. Nothing stops until you confirm.")
    }

    private var helpText: String {
        [action.title, action.detail, "Nothing stops until you confirm the preview."]
            .compactMap { $0 }
            .joined(separator: " — ")
    }
}
