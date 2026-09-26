import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A notification's Snooze can relaunch the app, which then has no sample
/// and no families yet; the snooze must still be saved.
@MainActor
final class SnoozeBySignatureTests: XCTestCase {
    func testSnoozeBySignatureBeforeTheFirstSampleSavesTheRule() async {
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        XCTAssertTrue(monitor.families.isEmpty)
        let before = Date()
        await monitor.snooze(signatureID: "vite|/usr/local/bin/node|abc123", name: "vite", minutes: 60)

        let rule = monitor.rules.first { $0.action == .snooze }
        XCTAssertEqual(rule?.match.signatureID, "vite|/usr/local/bin/node|abc123")
        XCTAssertEqual(rule?.name, "Snooze vite")
        XCTAssertEqual(rule?.match.minimumLevel, .quiet)
        XCTAssertFalse(rule?.isBuiltIn ?? true)
        let expiry = try? XCTUnwrap(rule?.expiresAt)
        XCTAssertEqual(expiry?.timeIntervalSince(before) ?? 0, 3_600, accuracy: 5)
    }

    func testSnoozeBySignatureOfALiveFamilyUsesTheFamily() async {
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(
            currentUserID: DevWorkstationFixture.user, directoryExists: { _ in true }), store: nil)
        await monitor.ingest(DevWorkstationFixture.processes(count: 120, tick: 0), now: DevWorkstationFixture.date(tick: 0))
        guard let family = monitor.families.first else {
            return XCTFail("the fixture process should form a family")
        }
        await monitor.snooze(signatureID: family.signature.id, name: "stale name", minutes: 30)
        let rule = monitor.rules.first { $0.action == .snooze }
        XCTAssertEqual(rule?.match.signatureID, family.signature.id)
        XCTAssertEqual(rule?.name, "Snooze \(family.displayName)")
    }
}
