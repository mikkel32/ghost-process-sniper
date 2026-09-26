import GhostProcessSniperCore
import SwiftUI

/// Each adaptive layout candidate owns its namespace, avoiding duplicate
/// matched-geometry sources when ViewThatFits measures both candidates.
struct ProcessFilterBar: View {
    @Bindable var session: RadarConsoleSession
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RadarFilter.allCases, id: \.self) { filter in
                Button { session.state.familyFilter = filter } label: {
                    Text(filter == .killable ? "Can stop" : filter.label)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .foregroundStyle(session.state.familyFilter == filter ? Color.primary : Color.secondary)
                        .background {
                            RadarSelectionSurface(selected: session.state.familyFilter == filter,
                                                  namespace: selectionNamespace, key: "process-filter")
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(session.state.familyFilter == filter ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }
}
