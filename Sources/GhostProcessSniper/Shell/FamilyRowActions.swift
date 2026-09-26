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
    let row: CompactSidebarRowModel
    let session: RadarConsoleSession

    private var familyKey: String { row.id }

    func body(content: Content) -> some View {
        let quickStop = session.quickStops.actions[familyKey]
        return content.contextMenu {
            Button {
                session.focus(.family(familyKey))
            } label: {
                Label("Show Details", systemImage: "sidebar.right")
            }

            Menu {
                FamilySnoozeMenu { minutes in
                    session.snooze(familyKey: familyKey, name: row.title, minutes: minutes)
                }
            } label: {
                Label("Snooze", systemImage: "moon")
            }

            Button {
                session.ignore(familyKey: familyKey, name: row.title)
            } label: {
                Label("Ignore Family", systemImage: "eye.slash")
            }

            Divider()

            // The Quick Stop advisor names the risk-aware verb when it has one;
            // otherwise the preview names the exact verb.
            Button(role: .destructive) {
                if let quickStop, quickStop.isAvailable {
                    session.quickStop(quickStop)
                } else {
                    session.prepareKill(familyKey: familyKey, name: row.title)
                }
            } label: {
                Label(
                    quickStop?.title ?? StopActionLabel.title(risk: nil, memberCount: 0),
                    systemImage: quickStop?.systemImage ?? "stop.circle"
                )
            }
            .disabled(quickStop?.isAvailable == false)

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
            Button {
                session.copyToPasteboard("\(row.title) — \(row.subtitle)\n\(row.metricText)", toast: "Copied \(row.title) summary")
            } label: {
                Label("Copy Summary", systemImage: "doc.on.clipboard")
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
        modifier(FamilyRowActionsModifier(row: row, session: session))
    }
}
