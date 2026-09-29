import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The Incidents detail pane says how often an app's episodes recur, in
/// facts: a count, a typical length, a peak range. It never judges them.
final class IncidentPatternTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000_000)
    private let minute: TimeInterval = 60

    // MARK: Grouping

    func testCountsOneSignatureAndNeverMixesAnotherIn() {
        let incidents = (0..<9).map { build(name: "xcodebuild", index: $0) }
            + (0..<3).map { build(name: "node", index: $0 + 20) }
            + [build(name: "Claude", index: 40)]
        let patterns = IncidentPattern.bySignature(in: incidents)

        XCTAssertEqual(patterns[signatureID("xcodebuild")]?.episodes, 9)
        XCTAssertEqual(patterns[signatureID("node")]?.episodes, 3)
        XCTAssertNil(patterns[signatureID("Claude")], "a single episode has no pattern to describe")
        XCTAssertEqual(patterns.count, 2)
    }

    func testTwoEpisodesAreTheSmallestPattern() {
        let patterns = IncidentPattern.bySignature(in: [build(name: "a", index: 0), build(name: "a", index: 1)])
        XCTAssertEqual(patterns[signatureID("a")]?.episodes, 2)
        XCTAssertTrue(IncidentPattern.bySignature(in: []).isEmpty)
    }

    // MARK: Text

    func testEpisodesAreCountedFromTheOldestOneInTheList() throws {
        let incidents = (0..<9).map { build(name: "xcodebuild", index: $0) }
        let pattern = try XCTUnwrap(IncidentPattern.bySignature(in: incidents)[signatureID("xcodebuild")])

        let oldest = incidents.map(\.startedAt).min()!
        XCTAssertEqual(pattern.episodesText, "9 since " + oldest.formatted(date: .abbreviated, time: .omitted))
    }

    func testTypicalLengthIsTheMedianOfTheEpisodesThatEnded() throws {
        let incidents = [
            build(name: "a", index: 0, lasted: 2 * minute),
            build(name: "a", index: 1, lasted: 3 * minute),
            build(name: "a", index: 2, lasted: 30 * minute),
            build(name: "a", index: 3, lasted: 90 * minute, resolved: false)
        ]
        let pattern = try XCTUnwrap(IncidentPattern.bySignature(in: incidents)[signatureID("a")])
        XCTAssertEqual(pattern.episodes, 4)
        XCTAssertEqual(pattern.lengthText, "3 min", "the episode still running has no length yet, and the 30-minute outlier does not drag the middle")
    }

    func testTypicalLengthNeedsTwoEndedEpisodes() throws {
        let incidents = [
            build(name: "a", index: 0, lasted: 2 * minute),
            build(name: "a", index: 1, lasted: 5 * minute, resolved: false)
        ]
        let pattern = try XCTUnwrap(IncidentPattern.bySignature(in: incidents)[signatureID("a")])
        XCTAssertNil(pattern.lengthText, "one ended episode is its own median, not a typical length")
    }

    func testPeakTextGivesTheRangeWithTheRowsOwnFormatting() throws {
        let small = [
            build(name: "a", index: 0, peak: 195 * mb),
            build(name: "a", index: 1, peak: 640 * mb),
            build(name: "a", index: 2, peak: 900 * mb)
        ]
        XCTAssertEqual(IncidentPattern.bySignature(in: small)[signatureID("a")]?.peakText, "195 MB to 900 MB")

        // Whatever the machine's locale, the range reads exactly like the table's Memory column.
        let wide = [build(name: "b", index: 0, peak: 195 * mb), build(name: "b", index: 1, peak: 3_800 * mb)]
        let text = try XCTUnwrap(IncidentPattern.bySignature(in: wide)[signatureID("b")]).peakText
        XCTAssertEqual(text, "\(RadarFormat.bytes(195 * mb)) to \(RadarFormat.bytes(3_800 * mb))")
        XCTAssertEqual(text, "\(IncidentRowViewModel(incident: wide[0]).memoryText) to \(IncidentRowViewModel(incident: wide[1]).memoryText)")
    }

    func testEqualPeaksAreOneValue() {
        let same = [build(name: "a", index: 0, peak: 700 * mb), build(name: "a", index: 1, peak: 700 * mb)]
        XCTAssertEqual(IncidentPattern.bySignature(in: same)[signatureID("a")]?.peakText, "700 MB")
    }

    func testItDescribesAndNeverJudges() throws {
        let incidents = (0..<9).map { build(name: "xcodebuild", index: $0, lasted: 3 * minute, peak: 3_700 * mb) }
        let pattern = try XCTUnwrap(IncidentPattern.bySignature(in: incidents)[signatureID("xcodebuild")])
        // Nine identical episodes are still not "routine": recurrence is evidence the scorer counts against a family.
        for text in [pattern.episodesText, pattern.lengthText ?? "", pattern.peakText] {
            for word in ["routine", "usual", "normal", "harmless", "ignore", "safe"] {
                XCTAssertFalse(text.lowercased().contains(word), "\"\(text)\" passes a verdict")
            }
        }
    }

    // MARK: Rows

    func testRowsCarryTheirSignaturesPattern() {
        let incidents = (0..<3).map { build(name: "xcodebuild", index: $0) } + [build(name: "Claude", index: 10)]
        let rows = ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: incidents, state: .default).incidentRows

        XCTAssertEqual(rows.filter { $0.familyName == "xcodebuild" }.map { $0.recurrence?.episodes }, [3, 3, 3])
        XCTAssertNil(rows.first { $0.familyName == "Claude" }?.recurrence)
        XCTAssertNil(IncidentRowViewModel(incident: incidents[0]).recurrence, "a row built alone knows nothing of the others")
    }

    func testAFilterOrSearchDoesNotChangeTheCounts() {
        var incidents = (0..<6).map { build(name: "xcodebuild", index: $0) }
        incidents[0].resolvedAt = nil
        incidents[1].level = .critical

        func episodes(_ query: IncidentQuery) -> [Int?] {
            var state = RadarConsoleState.default
            state.incidentQuery = query
            return ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: incidents, state: state).incidentRows.map { $0.recurrence?.episodes }
        }
        XCTAssertEqual(episodes(.default), Array(repeating: 6, count: 6))
        XCTAssertEqual(episodes(IncidentQuery(filter: .resolved)), Array(repeating: 6, count: 5), "hiding rows must not hide episodes from the count")
        XCTAssertEqual(episodes(IncidentQuery(filter: .critical)), [6])
        XCTAssertEqual(episodes(IncidentQuery(text: "xcodebuild", filter: .active)), [6])
    }

    func testTheLoadedLogWidensTheCount() {
        let log = (0..<9).map { build(name: "xcodebuild", index: $0) }.reversed() as [RadarIncident]
        let published = Array(log.prefix(3))
        let history = IncidentHistory(incidents: log, revision: 1, writeCount: 0, isTruncated: false)

        let narrow = ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: published, state: .default).incidentRows
        XCTAssertEqual(narrow.first?.recurrence?.episodes, 3)
        var state = RadarConsoleState.default
        state.incidentQuery.text = "xcodebuild"
        let wide = ConsoleDerivedSnapshot.build(snapshot: .empty, incidents: published, incidentHistory: history, state: state).incidentRows
        XCTAssertEqual(wide.first?.recurrence?.episodes, 9, "the count follows the rows that were searched")
    }

    // MARK: Fixtures

    private let mb: UInt64 = 1_048_576

    private func signatureID(_ name: String) -> String {
        ProcessSignature(displayName: name, canonicalPath: "/bin/\(name)", commandLine: name).id
    }

    /// One episode of `name`, `index` hours after the start.
    private func build(
        name: String,
        index: Int,
        lasted: TimeInterval = 180,
        peak: UInt64 = 3_000_000_000,
        resolved: Bool = true
    ) -> RadarIncident {
        let began = start.addingTimeInterval(Double(index) * 3_600)
        return RadarIncident(
            signature: ProcessSignature(displayName: name, canonicalPath: "/bin/\(name)", commandLine: name),
            familyName: name, level: .hot, maxScore: 80, memoryBytes: peak, cpuPercent: 0,
            leakVelocityMegabytesPerMinute: 0, reasons: ["memory"],
            startedAt: began, lastSeenAt: began.addingTimeInterval(lasted),
            resolvedAt: resolved ? began.addingTimeInterval(lasted) : nil
        )
    }
}
