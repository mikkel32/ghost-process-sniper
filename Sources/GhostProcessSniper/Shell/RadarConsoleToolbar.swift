import GhostProcessSniperCore
import SwiftUI

struct RadarConsoleToolbar: ToolbarContent {
    @Bindable var session: RadarConsoleSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsFamilyControls: Bool {
        switch session.state.focusedSelection {
        case .overview, .processes, .family, .duplicates:
            true
        case .incidents, .rules, .engine:
            false
        }
    }

    private var hasSelectedFamily: Bool {
        session.state.focusedSelection.familyKey != nil
    }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                session.refresh()
            } label: {
                Label("Scan Now", systemImage: "dot.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, isActive: session.isRefreshing && !reduceMotion)
            }
            .keyboardShortcut("r")
            .disabled(session.isRefreshing)
            .help("Refresh the radar now")

            if showsFamilyControls {
                ControlGroup {
                    Button {
                        session.previousFamily()
                    } label: {
                        Label("Previous Family", systemImage: "chevron.up")
                    }
                    .disabled(!session.availability(.previousFamily).isEnabled)

                    Button {
                        session.nextFamily()
                    } label: {
                        Label("Next Family", systemImage: "chevron.down")
                    }
                    .disabled(!session.availability(.nextFamily).isEnabled)
                }
                .controlGroupStyle(.navigation)
                .help("Walk through process families (⌘↑ / ⌘↓)")

                Menu {
                    Picker("Filter", selection: $session.state.familyFilter) {
                        ForEach(RadarFilter.allCases, id: \.self) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }

                    Divider()

                    Picker("Sort", selection: $session.state.familySort) {
                        ForEach(RadarSort.allCases, id: \.self) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                } label: {
                    Label("View", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Filter and sort process families")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if hasSelectedFamily {
                Button {
                    session.toggleInspector()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Toggle the inspector panel (⌥⌘I)")

                // ⇧⌘⌫ comes from the Radar menu's Stop… item.
                Button(role: .destructive) {
                    session.prepareKillSelected()
                } label: {
                    Label("Stop…", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!session.canStopSelection)
                .help(session.canStopSelection
                    ? "Preview stopping the selected family — nothing runs without confirmation (⇧⌘⌫)"
                    : "No live processes owned by you to target")
            }

            Menu {
                Button {
                    session.copyDiagnostics()
                } label: {
                    Label("Copy Diagnostics", systemImage: "stethoscope")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button {
                    session.showQuickGuide = true
                } label: {
                    Label("Quick Guide & Shortcuts", systemImage: "questionmark.circle")
                }

                Button {
                    session.openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Diagnostics and settings")
        }
    }
}
