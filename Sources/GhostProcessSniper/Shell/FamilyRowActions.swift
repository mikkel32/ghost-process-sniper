import AppKit
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

private struct FamilyRowActionsModifier: ViewModifier {
    let row: CompactSidebarRowModel
    let session: RadarConsoleSession

    func body(content: Content) -> some View {
        let quickStop = session.quickStops.actions[row.id]
        return content.contextMenu {
            Button {
                session.focus(.family(row.id))
            } label: {
                Label("Show Details", systemImage: "sidebar.right")
            }

            Menu {
                FamilySnoozeMenu { minutes in
                    session.snooze(familyKey: row.id, name: row.title, minutes: minutes)
                }
            } label: {
                Label("Snooze", systemImage: "moon")
            }

            Button {
                session.ignore(familyKey: row.id, name: row.title)
            } label: {
                Label("Ignore Family", systemImage: "eye.slash")
            }

            Divider()

            Button(role: .destructive) {
                if let quickStop, quickStop.isAvailable {
                    session.quickStop(quickStop)
                } else {
                    session.prepareKill(familyKey: row.id, name: row.title)
                }
            } label: {
                Label(quickStop?.title ?? "Stop…", systemImage: quickStop?.systemImage ?? "scope")
            }
            .disabled(quickStop?.isAvailable == false)

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(row.title) — \(row.subtitle)\n\(row.metricText)", forType: .string)
                session.showToast("Copied \(row.title) summary", systemImage: "doc.on.clipboard")
            } label: {
                Label("Copy Summary", systemImage: "doc.on.clipboard")
            }
        }
    }
}

extension View {
    func familyRowActions(row: CompactSidebarRowModel, session: RadarConsoleSession) -> some View {
        modifier(FamilyRowActionsModifier(row: row, session: session))
    }
}
