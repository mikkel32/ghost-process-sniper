import XCTest
@testable import GhostProcessSniperCore

/// Several cores held at one level, below a limit that scales with the Mac.
final class SteadyBurnTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 600_000)

    /// Finished minutes at `cores` (with a small wobble), then the minute in progress.
    private func activity(_ cores: [Double], changes: Int = 0) -> FamilyCPUActivity {
        let buckets = (cores + [cores.last ?? 0]).enumerated().map { index, level in
            CPUMinuteBucket(start: start.addingTimeInterval(Double(index) * 60), cpuSeconds: level * 60,
                            wallSeconds: 60, dominantCPUSeconds: level * 30, memberChanges: changes)
        }
        return FamilyCPUActivity(buckets: buckets, lastActiveAt: start, measuredSince: start)
    }

    private func analyze(_ activity: FamilyCPUActivity, processors: Int = 8, unattended: Bool = false,
                         kind: DevProcessKind? = nil) -> CPUBehavior {
        let settings = ThresholdSettings.smart
        return CPUBehaviorAnalyzer.analyze(
            activity: activity,
            classification: kind.map { DevClassification(kind: $0, confidence: 0.9, reason: "fixture") },
            memberCount: 3, baseline: nil, processorCount: processors,
            cpuThreshold: CPUBehaviorAnalyzer.familyCPULimit(settings: settings, processorCount: processors),
            isUnattended: unattended)
    }

    private let threeCores = (0..<12).map { 3 + ($0.isMultiple(of: 2) ? 0.08 : -0.08) }

    func testThreeCoresHeldForTwelveMinutesIsSustainedEvidence() {
        let behavior = analyze(activity(threeCores))
        XCTAssertEqual(behavior.kind, .steadyBurn)
        XCTAssertTrue(behavior.isSustained)
        XCTAssertFalse(behavior.isRunaway, "someone may be watching this encode")
        XCTAssertEqual(behavior.minutes, 12)
    }

    func testNobodyAttendingItMakesItARunaway() {
        let behavior = analyze(activity(threeCores), unattended: true)
        XCTAssertTrue(behavior.isRunaway)
        XCTAssertTrue(behavior.reason.hasSuffix("with nobody attending it"), behavior.reason)
    }

    func testABigMacDoesNotHideIt() {
        // 720% is the family limit on sixteen cores; five steady cores stay below it.
        let behavior = analyze(activity((0..<12).map { _ in 5 }), processors: 16, unattended: true)
        XCTAssertEqual(behavior.kind, .steadyBurn)
        XCTAssertTrue(behavior.isRunaway)
    }

    func testUnevenShortChurningOrBuildWorkIsNot() {
        let uneven = (0..<12).map { $0.isMultiple(of: 2) ? 1.6 : 4.4 }
        XCTAssertEqual(analyze(activity(uneven), unattended: true).kind, .none)
        XCTAssertEqual(analyze(activity(Array(threeCores.prefix(8))), unattended: true).kind, .none)
        XCTAssertEqual(analyze(activity(threeCores, changes: 1), unattended: true).kind, .none)
        XCTAssertEqual(analyze(activity(threeCores), unattended: true, kind: .swiftBuild).kind, .expectedBurst)
        XCTAssertEqual(analyze(activity((0..<12).map { _ in 1.2 }), unattended: true).kind, .none, "under one and a half cores")
    }
}
