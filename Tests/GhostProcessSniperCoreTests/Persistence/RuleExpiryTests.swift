import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

final class RuleExpiryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSnoozeLeavesTheContextWhenItExpires() async throws {
        let store = RadarStore(url: folder.appendingPathComponent("Radar.sqlite"))
        let family = makeFamily(pid: 700)
        let snooze = snoozeRule(for: family, expiresAt: start.addingTimeInterval(60))
        try await store.saveRule(snooze)

        let during = try await store.context(for: [family], settings: .smart, now: start.addingTimeInterval(30))
        XCTAssertTrue(during.rules.contains { $0.id == snooze.id })
        let after = try await store.context(for: [family], settings: .smart, now: start.addingTimeInterval(61))
        XCTAssertFalse(after.rules.contains { $0.id == snooze.id })
    }

    func testPreviewStopsMatchingAnExpiredRule() {
        let family = makeFamily(pid: 701)
        let snooze = snoozeRule(for: family, expiresAt: start.addingTimeInterval(60))
        XCTAssertEqual(RuleMatchPreview(rule: snooze, families: [family], now: start.addingTimeInterval(30)).matchCount, 1)
        XCTAssertEqual(RuleMatchPreview(rule: snooze, families: [family], now: start.addingTimeInterval(61)).matchCount, 0)
    }

    func testBuiltInPreviewsAgreeWithTheEngine() {
        let unconfirmedHot = GhostHeat(value: 70, level: .hot, confidence: 0.2, evidence: [], sustainedSignalCount: 0)
        let confirmedHot = GhostHeat(value: 75, level: .hot, confidence: 0.7, evidence: [], sustainedSignalCount: 2)
        let critical = GhostHeat(value: 95, level: .critical, confidence: 0.9, evidence: [], sustainedSignalCount: 3)
        let families = [
            makeFamily(pid: 710, score: GhostScore(value: 80, level: .hot, reasons: ["cpu"], heat: unconfirmedHot)),
            makeFamily(pid: 711, score: GhostScore(value: 80, level: .hot, reasons: ["cpu"], heat: confirmedHot)),
            makeFamily(pid: 712, score: GhostScore(value: 90, level: .critical, reasons: ["memory"], heat: critical)),
            makeFamily(pid: 713)
        ]
        let engine = RadarRuleEngine()
        let rules = RadarRule.builtIns(settings: .smart)
        for rule in rules {
            let expected = families.filter { family in
                engine.suggestions(for: family, rules: rules, now: start).contains { $0.ruleID == rule.id }
            }
            let preview = RuleMatchPreview(rule: rule, families: families, now: start)
            XCTAssertEqual(preview.matchedFamilyKeys, expected.map(\.familyKey), rule.name)
        }
        let kill = rules.first { $0.action == .suggestKill }!
        XCTAssertFalse(RuleMatchPreview(rule: kill, families: families, now: start).matchedFamilyKeys.contains(families[0].familyKey),
                       "an unconfirmed hot family must not count as a kill match")
    }

    func testPruneDeletesExpiredRulesOnly() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let store = RadarStore(url: url)
        let family = makeFamily(pid: 720)
        let expired = snoozeRule(for: family, expiresAt: start.addingTimeInterval(60))
        let permanent = RadarRule(name: "Ignore node", match: RadarRuleMatch(commandContains: "node"), action: .ignore)
        try await store.saveRule(expired)
        try await store.saveRule(permanent)

        try await store.pruneIfNeeded(now: start.addingTimeInterval(61))

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT id FROM rules", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        XCTAssertEqual(ids, [permanent.id.uuidString])
    }

    private func snoozeRule(for family: ProcessFamily, expiresAt: Date) -> RadarRule {
        RadarRule(
            name: "Snooze \(family.displayName)",
            match: RadarRuleMatch(signatureID: family.signature.id, minimumLevel: .quiet),
            action: .snooze,
            expiresAt: expiresAt,
            createdAt: start
        )
    }

    private func makeFamily(pid: Int32, score: GhostScore = GhostScore(value: 0, level: .quiet, reasons: [])) -> ProcessFamily {
        let identity = ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0)
        let name = "node-\(pid)"
        let root = ProcessMetrics(identity: identity, parentPID: 1, userID: 501, ownerName: "test", name: name,
                                  executablePath: "/usr/local/bin/\(name)", commandLine: "\(name) server.js",
                                  residentMemoryBytes: 32_000_000, physicalFootprintBytes: 32_000_000,
                                  virtualMemoryBytes: 64_000_000, cpuPercent: 0, totalProcessorSeconds: 10,
                                  threadCount: 2, isSystemProcess: false, sampledAt: start)
        return ProcessFamily(root: root, members: [root], totalResidentMemoryBytes: root.residentMemoryBytes,
                             totalPhysicalFootprintBytes: root.physicalFootprintBytes, totalCPUPercent: 0,
                             devConfidence: 0.9, commandHints: [root.commandLine], trend: .empty,
                             score: score, ownedIdentities: [identity], protectedPIDs: [], lastScoredAt: start)
    }
}
