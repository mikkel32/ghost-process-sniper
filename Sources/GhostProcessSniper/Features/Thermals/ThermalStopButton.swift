import GhostProcessSniperCore
import SwiftUI

/// Opens the regular stop preview for the family a heat suspect resolves to.
struct ThermalStopButton: View {
    let target: ThermalStopTarget
    let onStop: (String) -> Void

    var body: some View {
        Button(role: .destructive) {
            onStop(target.familyKey)
        } label: {
            Label(target.title, systemImage: "scope")
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("Preview how this family would be stopped. Nothing runs until you confirm.")
    }
}
