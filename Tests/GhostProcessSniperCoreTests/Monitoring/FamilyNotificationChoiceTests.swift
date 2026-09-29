import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Counts the passes a notifier is given.
private actor CountingNotifier: RadarNotifying {
    private(set) var calls = 0

    func process(model: RadarModel) async {
        calls += 1
    }
}

/// Turning process alerts off in Settings must stop them at the source: the
/// notifier is never asked, however often the radar refreshes.
@MainActor
final class FamilyNotificationChoiceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func makeMonitor(_ notifier: CountingNotifier, families: Bool) -> ProcessMonitor {
        var settings = ThresholdSettings.smart
        settings.notifications.families = families
        return ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501),
                              settings: settings, store: nil, notifier: notifier)
    }

    func testProcessAlertsAreOfferedToTheNotifierByDefault() async {
        let notifier = CountingNotifier()
        let monitor = makeMonitor(notifier, families: true)
        await monitor.refresh(now: start)
        let called = await waitUntil { await notifier.calls >= 1 }
        XCTAssertTrue(called)
    }

    func testTurnedOffTheNotifierIsNeverAsked() async {
        let notifier = CountingNotifier()
        let monitor = makeMonitor(notifier, families: false)
        for tick in 0..<4 {
            await monitor.refresh(now: start.addingTimeInterval(Double(tick)))
        }
        let called = await waitUntil(timeout: 0.3) { await notifier.calls > 0 }
        XCTAssertFalse(called, "no pass may reach the notifier while the choice is off")
    }

    func testTurningItBackOnResumesTheAlerts() async {
        let notifier = CountingNotifier()
        let monitor = makeMonitor(notifier, families: false)
        await monitor.refresh(now: start)
        _ = await waitUntil(timeout: 0.2) { await notifier.calls > 0 }
        let quiet = await notifier.calls
        XCTAssertEqual(quiet, 0)

        monitor.settings.notifications.families = true
        await monitor.refresh(now: start.addingTimeInterval(1))
        let resumed = await waitUntil { await notifier.calls >= 1 }
        XCTAssertTrue(resumed)
    }
}
