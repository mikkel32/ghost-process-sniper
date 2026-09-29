import Foundation

/// The keyboard shortcuts the Quick Guide lists, in the two columns it shows
/// them in, nine rows each so the sheet keeps its height. The Radar, Window
/// and app menus own the key bindings; this is the list a reader sees, kept
/// in Core so a test can hold it to those menus.
public enum RadarShortcutGuide {
    public struct Row: Equatable, Sendable {
        public let title: String
        public let keys: String

        init(_ title: String, _ keys: String) {
            self.title = title
            self.keys = keys
        }
    }

    public static let leadingColumn: [Row] = [
        Row("Find processes", "⌘F"),
        Row("Open best match", "↩"),
        Row("Scan now", "⌘R"),
        Row("Overview · All Processes", "⌘1 · ⌘2"),
        Row("Security · Energy", "⌘3 · ⌘4"),
        Row("Duplicates · Incidents", "⌘5 · ⌘6"),
        Row("Rules", "⌘7"),
        Row("Back · Forward", "⌘[ · ⌘]"),
        Row("Settings", "⌘,")
    ]

    public static let trailingColumn: [Row] = [
        Row("Next / previous family", "⌘↓ / ⌘↑ or ↓ / ↑"),
        Row("Stop…", "⇧⌘⌫"),
        Row("Snooze family", "⇧⌘S"),
        Row("Ignore family", "⇧⌘E"),
        Row("Toggle inspector", "⌥⌘I"),
        Row("Copy incident report", "⇧⌘C"),
        Row("Copy diagnostics", "⇧⌘D"),
        Row("Close window", "⌘W"),
        Row("Minimize", "⌘M")
    ]

    public static var all: [Row] { leadingColumn + trailingColumn }
}
