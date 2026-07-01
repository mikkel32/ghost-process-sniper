import GhostProcessSniperCore
import SwiftUI

struct RadarConsoleToolbar: ToolbarContent {
    @Bindable var session: RadarConsoleSession

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                session.refresh()
            } label: {
                Label("Refresh", systemImage: "dot.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, isActive: session.isRefreshing)
            }
            .keyboardShortcut("r")
            .help("Refresh the radar now")

            Button {
                session.previousFamily()
            } label: {
                Label("Previous Family", systemImage: "chevron.up")
            }
            .disabled(!session.availability(.previousFamily).isEnabled)
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .help("Select the previous family (⌘↑)")

            Button {
                session.nextFamily()
            } label: {
                Label("Next Family", systemImage: "chevron.down")
            }
            .disabled(!session.availability(.nextFamily).isEnabled)
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .help("Select the next family (⌘↓)")

            Picker(selection: $session.state.familyFilter) {
                ForEach(RadarFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
            .pickerStyle(.menu)
            .help("Filter the family lists")

            Picker(selection: $session.state.familySort) {
                ForEach(RadarSort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down.circle")
            }
            .pickerStyle(.menu)
            .help("Order the family lists")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.toggleInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Toggle the inspector panel (⌥⌘I)")

            Button {
                session.copyDiagnostics()
            } label: {
                Label("Copy Diagnostics", systemImage: "stethoscope")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help("Copy a full engine diagnostics report (⇧⌘D)")

            Button(role: .destructive) {
                session.prepareKillSelected()
            } label: {
                Label("Kill Tree", systemImage: "scope")
            }
            .disabled(!session.availability(.killPreview).isEnabled)
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .help(session.availability(.killPreview).isEnabled
                ? "Preview a kill of the selected family — nothing runs without confirmation (⇧⌘⌫)"
                : "Select a killable family first (⇧⌘⌫)")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open Settings (⌘,)")
        }
    }
}
