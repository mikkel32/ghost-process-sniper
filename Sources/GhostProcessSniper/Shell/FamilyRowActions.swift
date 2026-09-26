import GhostProcessSniperCore
import SwiftUI

private let snoozeChoices: [(label: String, minutes: TimeInterval)] = [
    ("15 Minutes", 15),
    ("1 Hour", 60),
    ("4 Hours", 240),
    ("Until Tomorrow", 24 * 60)
]

struct FamilySnoozeMenu: View {
    let snooze: (TimeInterval) -> Void

    var body: some View {
        ForEach(snoozeChoices, id: \.minutes) { choice in
            Button(choice.label) {
                snooze(choice.minutes)
            }
        }
    }
}

/// The context menu every family row shares: open, snooze, ignore, stop,
/// and copy or reveal what it runs.
private struct FamilyRowActionsModifier: ViewModifier {
    let familyKey: String
    let title: String
    /// Sidebar-style rows also offer their one-line summary.
    let summaryRow: CompactSidebarRowModel?
    let session: RadarConsoleSession

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                session.focus(.family(familyKey))
            } label: {
                Label("Show Details", systemImage: "sidebar.right")
            }

            Menu {
                FamilySnoozeMenu { minutes in
                    session.snooze(familyKey: familyKey, name: title, minutes: minutes)
                }
            } label: {
                Label("Snooze", systemImage: "moon")
            }

            Button {
                session.ignore(familyKey: familyKey, name: title)
            } label: {
                Label("Ignore Family", systemImage: "eye.slash")
            }

            Divider()

            // No risk assessment here; the preview names the exact verb.
            Button(role: .destructive) {
                session.prepareKill(familyKey: familyKey)
            } label: {
                Label(StopActionLabel.title(risk: nil, memberCount: 0), systemImage: "stop.circle")
            }

            Divider()

            Button {
                session.copyRootPID(familyKey: familyKey)
            } label: {
                Label("Copy PID", systemImage: "number")
            }
            Button {
                session.copyCommandLine(familyKey: familyKey)
            } label: {
                Label("Copy Command Line", systemImage: "terminal")
            }
            if let row = summaryRow {
                Button {
                    session.copyToPasteboard("\(row.title) — \(row.subtitle)\n\(row.metricText)", toast: "Copied \(row.title) summary")
                } label: {
                    Label("Copy Summary", systemImage: "doc.on.clipboard")
                }
            }
            Button {
                session.revealInFinder(familyKey: familyKey)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }
}

extension View {
    func familyRowActions(row: CompactSidebarRowModel, session: RadarConsoleSession) -> some View {
        modifier(FamilyRowActionsModifier(familyKey: row.id, title: row.title, summaryRow: row, session: session))
    }

    func familyRowActions(familyKey: String, title: String, session: RadarConsoleSession) -> some View {
        modifier(FamilyRowActionsModifier(familyKey: familyKey, title: title, summaryRow: nil, session: session))
    }
}
