import Foundation
import XCTest
import GhostProcessSniperCore

final class ConsoleNavigationTests: XCTestCase {
    func testDestinationsRoundTripWithoutLosingFamilyKeys() {
        let destinations: [RadarFocusedSelection] = [
            .overview, .processes, .duplicates, .incidents, .rules,
            .family("/usr/local/bin/node|project with spaces|ø")
        ]
        for destination in destinations {
            XCTAssertEqual(RadarFocusedSelection(storageValue: destination.storageValue), destination)
        }
    }

    func testUnknownAndEmptySavedDestinationsRecoverToOverview() {
        for value in ["", "retired-screen", "family|", "OVERVIEW"] {
            XCTAssertEqual(RadarFocusedSelection(storageValue: value), .overview)
        }
    }

    func testRetiredEngineDestinationLandsOnOverview() {
        XCTAssertEqual(RadarFocusedSelection(storageValue: "engine"), .overview)
        XCTAssertEqual(RadarConsoleState.default.focusedSelection, .overview)
    }

    func testSignatureSelectionIsRewrittenToTheLiveFamilyKey() {
        let family = makeFamily(pid: 42)
        let router = RadarCommandRouter()

        XCTAssertEqual(router.canonicalSelection(.family(family.signature.id), families: [family]), .family(family.familyKey))
        XCTAssertEqual(router.canonicalSelection(.family(family.familyKey), families: [family]), .family(family.familyKey))
        XCTAssertEqual(router.canonicalSelection(.family("exited"), families: [family]), .family("exited"))
        XCTAssertEqual(router.canonicalSelection(.incidents, families: [family]), .incidents)
    }

    func testBrowserDoesNotImplyASelectedProcess() {
        XCTAssertNil(RadarFocusedSelection.processes.familyKey)
        XCTAssertEqual(RadarFocusedSelection.family("example").familyKey, "example")
    }

    func testFamilyNavigationUsesVisibleOrderAndWraps() {
        let coordinator = RadarCommandCoordinator()
        let keys = ["largest", "middle", "smallest"]
        XCTAssertEqual(coordinator.selection(after: .family("largest"), orderedFamilyKeys: keys, direction: 1), .family("middle"))
        XCTAssertEqual(coordinator.selection(after: .family("smallest"), orderedFamilyKeys: keys, direction: 1), .family("largest"))
        XCTAssertEqual(coordinator.selection(after: .family("largest"), orderedFamilyKeys: keys, direction: -1), .family("smallest"))
    }

    func testNavigationFromMissingFamilyUsesTheVisibleResults() {
        let coordinator = RadarCommandCoordinator()
        XCTAssertEqual(coordinator.selection(after: .family("filtered-out"), orderedFamilyKeys: ["only-match"], direction: 1), .family("only-match"))
        XCTAssertEqual(coordinator.selection(after: .processes, orderedFamilyKeys: ["first", "last"], direction: -1), .family("last"))
    }

    func testEmptyResultsAndZeroMovementPreserveSelection() {
        let coordinator = RadarCommandCoordinator()
        XCTAssertEqual(coordinator.selection(after: .processes, orderedFamilyKeys: [], direction: 1), .processes)
        XCTAssertEqual(coordinator.selection(after: .family("a"), orderedFamilyKeys: ["a", "b"], direction: 0), .family("a"))
    }

    func testNavigationNormalizesLargeNegativeSteps() {
        let coordinator = RadarCommandCoordinator()
        XCTAssertEqual(coordinator.selection(after: .family("a"), orderedFamilyKeys: ["a", "b", "c"], direction: -4), .family("c"))
    }

    func testInspectorNeedsAFamilyPage() {
        let family = makeFamily(pid: 42)
        let router = RadarCommandRouter()
        for page: RadarFocusedSelection in [.overview, .processes, .duplicates, .incidents, .rules, .security, .energy] {
            let availability = router.availability(for: .toggleInspector, selection: page, families: [family])
            XCTAssertFalse(availability.isEnabled, "\(page) has no inspector to toggle")
            XCTAssertNotNil(availability.reason)
        }
        // The key is what counts, as for the toolbar button: a family that just
        // exited still shows its page, and its inspector can be closed.
        for key in [family.familyKey, family.signature.id, "exited"] {
            XCTAssertTrue(router.availability(for: .toggleInspector, selection: .family(key), families: [family]).isEnabled)
        }
    }

    func testSnoozeAndIgnoreNeedALiveFamily() {
        let family = makeFamily(pid: 42)
        let router = RadarCommandRouter()
        for command in [RadarCommand.snooze, .ignore] {
            XCTAssertTrue(router.availability(for: command, selection: .family(family.familyKey), families: [family]).isEnabled)
            XCTAssertFalse(router.availability(for: command, selection: .family("exited"), families: [family]).isEnabled,
                           "a page whose family has left the scan has nothing to \(command)")
            XCTAssertFalse(router.availability(for: command, selection: .overview, families: [family]).isEnabled)
        }
    }

    func testHistoryStepsBackAndForward() {
        var history = NavigationHistory()
        history.visit(.overview)
        history.visit(.family("a"))
        history.visit(.incidents)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(), .family("a"))
        XCTAssertEqual(history.goBack(), .overview)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), .family("a"))
        XCTAssertEqual(history.current, .family("a"))
        XCTAssertEqual(history.previous, .overview)
    }

    func testHistoryCollapsesRepeatsAndDropsTheForwardTrailOnANewVisit() {
        var history = NavigationHistory()
        history.visit(.overview)
        history.visit(.overview)
        history.visit(.processes)
        history.visit(.processes)
        XCTAssertEqual(history.entries, [.overview, .processes])
        _ = history.goBack()
        history.visit(.rules)
        XCTAssertEqual(history.entries, [.overview, .rules])
        XCTAssertFalse(history.canGoForward)
    }

    func testHistoryKeepsOnlyTheMostRecentSteps() {
        var history = NavigationHistory()
        for index in 0..<(NavigationHistory.capacity + 5) {
            history.visit(.family("f\(index)"))
        }
        XCTAssertEqual(history.entries.count, NavigationHistory.capacity)
        XCTAssertEqual(history.entries.first, .family("f5"))
        XCTAssertEqual(history.current, .family("f\(NavigationHistory.capacity + 4)"))
    }

    func testPruneDropsExitedFamiliesButKeepsThePageOnScreen() {
        var history = NavigationHistory()
        history.visit(.overview)
        history.visit(.family("gone"))
        history.visit(.overview)
        history.visit(.family("live"))
        history.visit(.family("stopped"))
        history.prune(liveFamilyKeys: ["live"])
        XCTAssertEqual(history.entries, [.overview, .family("live"), .family("stopped")], "repeated Overview entries collapse")
        XCTAssertEqual(history.current, .family("stopped"))
        XCTAssertEqual(history.goBack(), .family("live"))
        XCTAssertEqual(history.goBack(), .overview)
    }

    func testPruneKeepsTheIndexOnTheSamePage() {
        var history = NavigationHistory()
        history.visit(.family("gone"))
        history.visit(.processes)
        history.visit(.family("gone-too"))
        _ = history.goBack()
        history.prune(liveFamilyKeys: [])
        XCTAssertEqual(history.entries, [.processes])
        XCTAssertEqual(history.current, .processes)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    private func makeFamily(pid: Int32) -> ProcessFamily {
        let root = ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 100, startTimeMicroseconds: 0),
            parentPID: 1, userID: 501, ownerName: "me", name: "node", executablePath: "/usr/local/bin/node",
            commandLine: "node dev", residentMemoryBytes: 1, physicalFootprintBytes: 1, virtualMemoryBytes: 1,
            cpuPercent: 0, totalProcessorSeconds: 0, threadCount: 1, isSystemProcess: false,
            sampledAt: Date(timeIntervalSince1970: 1_000)
        )
        return ProcessFamily(
            root: root, members: [root], totalResidentMemoryBytes: 1, totalPhysicalFootprintBytes: 1,
            totalCPUPercent: 0, devConfidence: 0.5, commandHints: [], trend: .empty,
            score: GhostScore(value: 0, level: .quiet, reasons: []), ownedIdentities: [root.identity], protectedPIDs: []
        )
    }
}
