import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A booted simulator is one family rooted at `launchd_sim`, a name that
/// tells most people nothing; the runtime folder in its path does.
final class FamilyTitleTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private static let volume = "/Library/Developer/CoreSimulator/Volumes/iOS_22A/Library/Developer/CoreSimulator/Profiles/Runtimes"

    private func simulator(runtime: String = "iOS 18.0.simruntime", name: String = "launchd_sim", path: String? = nil) -> ProcessMetrics {
        let path = path ?? "\(Self.volume)/\(runtime)/Contents/Resources/RuntimeRoot/sbin/launchd_sim"
        return Fixture.process(pid: 700, name: name, path: path, command: "launchd_sim", megabytes: 900)
    }

    func testASimulatorIsNamedByItsRuntime() {
        XCTAssertEqual(Fixture.family(simulator()).displayName, "iOS 18.0 Simulator")
        XCTAssertEqual(Fixture.family(simulator(runtime: "watchOS 11.0.simruntime")).displayName, "watchOS 11.0 Simulator")
        XCTAssertEqual(Fixture.family(simulator(runtime: "iOS 26.5.simruntime")).displayName, "iOS 26.5 Simulator")
    }

    /// Xcode's own runtimes carry no version in the folder name.
    func testAnXcodeBundledRuntimeIsNamedByItsPlatform() {
        let path = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/Runtimes"
            + "/iOS.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim"
        XCTAssertEqual(Fixture.family(simulator(path: path)).displayName, "iOS Simulator")
    }

    func testWithoutARuntimeInThePathTheProcessNameStays() {
        XCTAssertEqual(Fixture.family(simulator(path: "")).displayName, "launchd_sim")
        XCTAssertEqual(Fixture.family(simulator(path: "/usr/local/bin/launchd_sim")).displayName, "launchd_sim")
        XCTAssertEqual(Fixture.family(simulator(path: "/x/.simruntime/sbin/launchd_sim")).displayName, "launchd_sim", "an empty runtime name says nothing")
    }

    /// Only the simulator's own root is renamed, whatever else sits in a runtime.
    func testOtherProcessesKeepTheirNames() {
        let path = "\(Self.volume)/iOS 18.0.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/backboardd"
        XCTAssertEqual(Fixture.family(simulator(name: "backboardd", path: path)).displayName, "backboardd")
        XCTAssertEqual(Fixture.family(Fixture.process(name: "node", path: "/usr/local/bin/node")).displayName, "node")
    }

    /// Baselines, rules and snoozes are keyed by the signature and the root,
    /// which still say `launchd_sim`; only what is shown changes.
    func testTheKeyAndSignatureStillNameTheProcess() {
        let root = simulator()
        let family = Fixture.family(root)
        XCTAssertEqual(family.signature.displayName, "launchd_sim")
        XCTAssertEqual(family.familyKey, ProcessFamily.key(signature: ProcessSignature.from(root: root), root: root.identity))
        XCTAssertTrue(family.signature.id.hasPrefix("launchd_sim|"), family.signature.id)
    }

    func testTheStopPlanAndABuiltFamilyUseTheReadableName() throws {
        let root = simulator()
        XCTAssertEqual(Fixture.family(root).killPlan().displayName, "iOS 18.0 Simulator")

        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([root], window: &window).first)
        XCTAssertEqual(family.displayName, "iOS 18.0 Simulator")
    }

    func testTwoRuntimesAreToldApart() {
        let names = [simulator(runtime: "iOS 18.0.simruntime"), simulator(runtime: "iOS 26.5.simruntime")].map { Fixture.family($0).displayName }
        XCTAssertEqual(names, ["iOS 18.0 Simulator", "iOS 26.5 Simulator"])
    }

    // MARK: - Search

    /// The console still finds it by the process name people know from
    /// Activity Monitor, and says so instead of highlighting letters of a
    /// title they were never matched against.
    func testSearchByTheProcessNameStillFindsTheFamily() throws {
        let family = Fixture.family(simulator())
        for query in ["launchd_sim", "launchd"] {
            let result = project(query, family: family)
            XCTAssertEqual(result.familyRows.map(\.familyKey), [family.familyKey], query)
            let row = try XCTUnwrap(result.browserRows.first)
            XCTAssertEqual(row.name, "iOS 18.0 Simulator", query)
            XCTAssertTrue(row.nameHighlights.isEmpty, "highlights measured on `launchd_sim` do not fit the title: \(row.nameHighlights)")
            XCTAssertEqual(row.detail, "Process: launchd_sim", query)
        }
    }

    /// Rows searched without a live sample are matched on the process name too.
    func testRowsSearchedWithoutASampleAreFoundByTheProcessName() {
        let family = Fixture.family(simulator())
        let result = ConsoleSearchProjection.run(rows: [FamilyTriageViewModel(family: family)], query: ProcessSearchQuery("launchd_sim"),
                                                 filter: .all, sort: .smart, index: nil)
        XCTAssertEqual(result.rows.map(\.familyKey), [family.familyKey])
        XCTAssertEqual(result.results.familyMatches[family.familyKey]?.nameHighlights, [0..<11])
    }

    func testSearchByWhatTheTitleSaysFindsItToo() {
        let family = Fixture.family(simulator())
        XCTAssertEqual(project("18.0", family: family).familyRows.map(\.familyKey), [family.familyKey], "the runtime is in the path")
        XCTAssertEqual(project("simulator", family: family).familyRows.map(\.familyKey), [family.familyKey])
    }

    func testOrdinaryFamiliesKeepTheirHighlightsAndReasons() throws {
        let node = Fixture.family(Fixture.process(pid: 710, name: "node", path: "/usr/local/bin/node", command: "node server.js"))
        let row = try XCTUnwrap(project("nod", family: node).browserRows.first)
        XCTAssertEqual(row.name, "node")
        XCTAssertEqual(row.nameHighlights, [0..<3])
        XCTAssertNotEqual(row.detail, "Process: node")
    }

    /// A query that matched only something else about a retitled family
    /// does not claim its process name matched.
    func testAMatchElsewhereKeepsTheReason() throws {
        let family = Fixture.family(simulator())
        let row = try XCTUnwrap(project("path:CoreSimulator", family: family).browserRows.first)
        XCTAssertTrue(row.nameHighlights.isEmpty)
        XCTAssertNotEqual(row.detail, "Process: launchd_sim")
    }

    private func project(_ text: String, family: ProcessFamily) -> ConsoleDerivedSnapshot {
        var state = RadarConsoleState.default
        state.searchText = text
        let snapshot = RadarConsoleSnapshot.build(
            families: [family], summary: ProcessFamilyBuilder(currentUserID: 501).summary(for: [family]), incidents: [], rules: [],
            metrics: .empty, health: .starting, storeHealth: .empty, storeError: nil, previous: nil, generatedAt: Fixture.now)
        var cache = ConsoleDerivedSnapshotCache()
        return cache.update(ConsoleProjectionRequest(source: snapshot, incidents: [], state: state, families: [family],
                                                     processes: family.members, sampleRevision: 1))
    }
}
