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

    // A family that exited (or restarted under a new pid) since the row was
    // drawn still has its rule saved: the key's instance suffix is dropped and
    // the rule matches the signature, so it also holds for the restarted copy.
    private let exitedKey = "vite|/usr/local/bin/node|abc123|pid:812|start:100.0"

    func testSnoozeOfAnExitedFamilyStillSavesTheRuleForItsSignature() async {
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        await monitor.snooze(signatureID: exitedKey, minutes: 30)

        let rule = monitor.rules.first { $0.action == .snooze }
        XCTAssertEqual(rule?.match.signatureID, "vite|/usr/local/bin/node|abc123")
        XCTAssertEqual(rule?.name, "Snooze vite", "with no name given, the signature's own name titles the rule")
        XCTAssertNotNil(rule?.expiresAt)
    }

    func testTheCallersNameTitlesTheRuleOfAnExitedFamily() async {
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        await monitor.snooze(signatureID: exitedKey, name: "Vite", minutes: 30)
        await monitor.ignore(signatureID: exitedKey, name: "Vite")

        XCTAssertEqual(monitor.rules.first { $0.action == .snooze }?.name, "Snooze Vite")
        XCTAssertEqual(monitor.rules.first { $0.action == .ignore }?.name, "Ignore Vite")
    }

    func testIgnoreOfAnExitedFamilyStillSavesTheRule() async {
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        await monitor.ignore(signatureID: exitedKey)

        let rule = monitor.rules.first { $0.action == .ignore }
        XCTAssertEqual(rule?.match.signatureID, "vite|/usr/local/bin/node|abc123")
        XCTAssertEqual(rule?.name, "Ignore vite")
        XCTAssertNil(rule?.expiresAt, "ignoring does not expire")
        XCTAssertFalse(rule?.isBuiltIn ?? true)
    }

    func testANothingKeySavesNoRule() async {
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        for key in ["", "|pid:812|start:100.0"] {
            await monitor.snooze(signatureID: key, minutes: 30)
            await monitor.ignore(signatureID: key)
        }
        XCTAssertNil(monitor.rules.first { $0.action == .snooze || $0.action == .ignore })
    }

    func testAFamilyKeyOfALiveFamilyStillUsesTheFamily() async {
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(
            currentUserID: DevWorkstationFixture.user, directoryExists: { _ in true }), store: nil)
        await monitor.ingest(DevWorkstationFixture.processes(count: 120, tick: 0), now: DevWorkstationFixture.date(tick: 0))
        guard let family = monitor.families.first else {
            return XCTFail("the fixture process should form a family")
        }
        await monitor.ignore(signatureID: family.familyKey, name: "stale name")
        let rule = monitor.rules.first { $0.action == .ignore }
        XCTAssertEqual(rule?.match.signatureID, family.signature.id)
        XCTAssertEqual(rule?.name, "Ignore \(family.displayName)")
    }
}

final class FamilyKeySignatureTests: XCTestCase {
    func testTheSignatureIDInsideAFamilyKeyRoundTrips() {
        let signature = ProcessSignature(displayName: "Vite", canonicalPath: "/usr/local/bin/node", commandLine: "node vite")
        let root = ProcessIdentity(pid: 812, startTimeSeconds: 1_700_000_000, startTimeMicroseconds: 250_000)
        let key = ProcessFamily.key(signature: signature, root: root)
        XCTAssertNotEqual(key, signature.id)
        XCTAssertEqual(ProcessFamily.signatureID(fromFamilyKey: key), signature.id)
        XCTAssertEqual(ProcessFamily.signatureID(fromFamilyKey: signature.id), signature.id, "a plain signature id is unchanged")
    }

    func testOnlyTheTrailingInstanceSuffixIsStripped() {
        XCTAssertEqual(ProcessFamily.signatureID(fromFamilyKey: "a|pid:1|start:2.3|pid:812|start:100.0"), "a|pid:1|start:2.3")
        for notAKey in ["x|pid:abc|start:1.0", "x|pid:1|start:1", "x|pid:1", "x|start:1.0", "x|pid:|start:1.0", "x|pid:1|start:1.0|extra", ""] {
            XCTAssertEqual(ProcessFamily.signatureID(fromFamilyKey: notAKey), notAKey)
        }
    }
}
