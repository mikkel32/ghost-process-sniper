import XCTest
import GhostProcessSniperCore

final class ConsoleNavigationTests: XCTestCase {
    func testDestinationsRoundTripWithoutLosingFamilyKeys() {
        let destinations: [RadarFocusedSelection] = [
            .overview, .processes, .duplicates, .incidents, .rules, .engine,
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

    func testExplicitEngineDestinationRemainsEngine() {
        XCTAssertEqual(RadarFocusedSelection(storageValue: "engine"), .engine)
    }

    func testBrowserDoesNotImplyASelectedProcess() {
        XCTAssertNil(RadarFocusedSelection.processes.familyKey)
        XCTAssertNil(RadarFocusedSelection.processes.signatureID)
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
        history.visit(.engine)
        XCTAssertEqual(history.entries, [.overview, .engine])
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
}
