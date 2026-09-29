import XCTest
@testable import GhostProcessSniperCore

/// The Quick Guide is the only shortcut reference in an app with no visible
/// menu bar, so it has to list what the menus bind. The wiring itself lives in
/// the app target, which has no tests; this holds the list to the bindings.
final class RadarShortcutGuideTests: XCTestCase {
    private var guide: String { RadarShortcutGuide.all.map(\.keys).joined(separator: " ") }

    func testTheGuideListsTheWindowCommands() {
        XCTAssertEqual(RadarShortcutGuide.all.first { $0.title == "Close window" }?.keys, "⌘W")
        XCTAssertEqual(RadarShortcutGuide.all.first { $0.title == "Minimize" }?.keys, "⌘M")
    }

    func testTheGuideListsEveryRadarMenuShortcutThatActsInsideTheConsole() {
        // Open Console (⌘O) is left out: the guide is only ever read inside it.
        let bound = ["⌘F", "⌘R", "⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘[", "⌘]", "⌘↓", "⌘↑",
                     "⌥⌘I", "⇧⌘C", "⇧⌘D", "⇧⌘S", "⇧⌘E", "⇧⌘⌫", "⌘,"]
        for keys in bound {
            XCTAssertTrue(guide.contains(keys), "the guide does not list \(keys)")
        }
    }

    func testNoTwoRowsClaimTheSameKeys() {
        let combinations = RadarShortcutGuide.all.flatMap { row in
            row.keys.components(separatedBy: CharacterSet(charactersIn: "·/")).flatMap { $0.components(separatedBy: " or ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        XCTAssertEqual(combinations.count, Set(combinations).count, "\(combinations)")
        let titles = RadarShortcutGuide.all.map(\.title)
        XCTAssertEqual(titles.count, Set(titles).count)
    }

    func testStopReadsWithTheMacGlyphs() {
        XCTAssertEqual(RadarShortcutGuide.all.first { $0.title == "Stop…" }?.keys, "⇧⌘⌫")
        XCTAssertEqual(RadarShortcutGuide.all.first { $0.title == "Toggle inspector" }?.keys, "⌥⌘I")
    }
}
