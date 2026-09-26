import GhostProcessSniperCore
import SwiftUI

/// Opens the regular stop preview for the family a heat suspect resolves to.
/// Like QuickStopButton, it is red only when the stop is recommended.
struct ThermalStopButton: View {
    let target: ThermalStopTarget
    let onStop: (QuickStopAction) -> Void

    var body: some View {
        Button {
            onStop(target.action)
        } label: {
            Label(target.title, systemImage: target.action.systemImage)
        }
        .buttonStyle(.bordered)
        .tint(target.action.emphasis == .recommended ? Color.red : nil)
        .help("Preview how this family would be stopped. Nothing runs until you confirm.")
    }
}
