import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ConsoleRowModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    func testRulesAreClassifiedForTheirSection() {
        let signature = ProcessSignature(displayName: "node", canonicalPath: "/usr/local/bin/node", commandLine: "node dev")
        let snooze = RadarRule(name: "Snooze node", match: RadarRuleMatch(signatureID: signature.id, minimumLevel: .quiet),
                               action: .snooze, expiresAt: now.addingTimeInterval(3_600))
        let ignore = RadarRule(name: "Ignore node", match: RadarRuleMatch(signatureID: signature.id, minimumLevel: .quiet), action: .ignore)
        let custom = RadarRule(name: "Notify: vite", match: RadarRuleMatch(commandContains: "vite", minimumLevel: .watch), action: .notify)
        // The composer can build a snooze that matches a command, not a family.
        let composedSnooze = RadarRule(name: "Snooze: vite", match: RadarRuleMatch(commandContains: "vite", minimumLevel: .watch),
                                       action: .snooze)
        let builtIn = RadarRule.builtIns(settings: .smart).first!

        XCTAssertEqual(RuleRowViewModel(rule: snooze).kind, .snooze)
        XCTAssertEqual(RuleRowViewModel(rule: snooze).expiresAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(RuleRowViewModel(rule: ignore).kind, .ignore)
        XCTAssertNil(RuleRowViewModel(rule: ignore).expiresAt)
        XCTAssertEqual(RuleRowViewModel(rule: custom).kind, .custom)
        XCTAssertEqual(RuleRowViewModel(rule: composedSnooze).kind, .custom)
        XCTAssertEqual(RuleRowViewModel(rule: builtIn).kind, .builtIn)
    }

    func testIncidentColumnsMapToSorts() {
        XCTAssertEqual(RadarIncidentSort(incidentColumn: \IncidentRowViewModel.familyName), .name)
        XCTAssertEqual(RadarIncidentSort(incidentColumn: \IncidentRowViewModel.score), .severity)
        XCTAssertEqual(RadarIncidentSort(incidentColumn: \IncidentRowViewModel.memoryBytes), .memory)
        XCTAssertEqual(RadarIncidentSort(incidentColumn: \IncidentRowViewModel.occurrenceCount), .recurrence)
        XCTAssertEqual(RadarIncidentSort(incidentColumn: nil), .recent)
    }

    func testIncidentAscendingIsLiteral() {
        let incidents = [
            incident("beta", memory: 300, seenAt: 3),
            incident("alpha", memory: 100, seenAt: 1),
            incident("gamma", memory: 200, seenAt: 2)
        ]
        func names(_ sort: RadarIncidentSort, ascending: Bool) -> [String] {
            IncidentQuery(sort: sort, ascending: ascending).apply(to: incidents).map(\.familyName)
        }
        XCTAssertEqual(names(.memory, ascending: false), ["beta", "gamma", "alpha"])
        XCTAssertEqual(names(.memory, ascending: true), ["alpha", "gamma", "beta"])
        XCTAssertEqual(names(.name, ascending: true), ["alpha", "beta", "gamma"])
        XCTAssertEqual(names(.name, ascending: false), ["gamma", "beta", "alpha"])
        XCTAssertEqual(names(.recent, ascending: false), ["beta", "gamma", "alpha"])
    }

    func testRecurrenceSortOrdersByTheHitsShown() {
        var few = incident("few", memory: 100, seenAt: 3)
        few.occurrenceCount = 2
        var many = incident("many", memory: 100, seenAt: 1)
        many.occurrenceCount = 9
        var once = incident("once", memory: 100, seenAt: 2)
        once.occurrenceCount = 1
        let incidents = [few, many, once]
        XCTAssertEqual(IncidentQuery(sort: .recurrence).apply(to: incidents).map(\.familyName), ["many", "few", "once"])
        XCTAssertEqual(IncidentQuery(sort: .recurrence, ascending: true).apply(to: incidents).map(\.familyName), ["once", "few", "many"])
    }

    func testIncidentRowsKnowWhetherTheirFamilyStillRuns() {
        let root = ProcessMetrics(
            identity: ProcessIdentity(pid: 77, startTimeSeconds: 100, startTimeMicroseconds: 0),
            parentPID: 1, userID: 501, ownerName: "me", name: "beta", executablePath: "/bin/beta",
            commandLine: "beta", residentMemoryBytes: 1, physicalFootprintBytes: 1, virtualMemoryBytes: 1,
            cpuPercent: 0, totalProcessorSeconds: 0, threadCount: 1, isSystemProcess: false, sampledAt: now
        )
        let family = ProcessFamily(
            root: root, members: [root], totalResidentMemoryBytes: 1, totalPhysicalFootprintBytes: 1,
            totalCPUPercent: 0, devConfidence: 0.5, commandHints: [], trend: .empty,
            score: GhostScore(value: 0, level: .quiet, reasons: []), ownedIdentities: [root.identity], protectedPIDs: []
        )
        let live = incident("beta", memory: 1, seenAt: 1, signature: family.signature)
        let gone = incident("gone", memory: 1, seenAt: 2)
        let snapshot = RadarConsoleSnapshot.build(
            families: [family], summary: ProcessFamilyBuilder(currentUserID: 501).summary(for: [family]),
            incidents: [], rules: [], metrics: .empty, health: .starting, storeHealth: .empty,
            storeError: nil, previous: nil, generatedAt: now
        )

        let rows = ConsoleDerivedSnapshot.build(snapshot: snapshot, incidents: [live, gone], state: .default).incidentRows

        XCTAssertEqual(rows.first { $0.familyName == "beta" }?.liveFamilyKey, family.familyKey, "the concrete key, not the signature id")
        XCTAssertNil(rows.first { $0.familyName == "gone" }?.liveFamilyKey)
    }

    func testIncidentGrowthIsNeverNegativeOrZeroMegabytes() {
        // Rows written before peaks were tracked can hold a raw, negative slope.
        XCTAssertEqual(IncidentRowViewModel(incident: incident("shrinking", memory: 1, seenAt: 1, leak: -170)).leakText, "none")
        XCTAssertEqual(IncidentRowViewModel(incident: incident("flat", memory: 1, seenAt: 1, leak: 0.4)).leakText, "none")
        XCTAssertEqual(IncidentRowViewModel(incident: incident("climbing", memory: 1, seenAt: 1, leak: 247.4)).leakText, "247 MB/min")
    }

    func testIncidentDurationHasNoDecimalSeparator() {
        func duration(_ seconds: TimeInterval) -> String {
            var episode = incident("episode", memory: 1, seenAt: 0)
            episode.lastSeenAt = episode.startedAt.addingTimeInterval(seconds)
            return IncidentRowViewModel(incident: episode).durationText
        }
        XCTAssertEqual(duration(45), "45 s")
        XCTAssertEqual(duration(12 * 60), "12 min")
        XCTAssertEqual(duration(96_840), "27 h", "26.9 hours must not need a decimal point that the reader's locale spells differently")
        XCTAssertEqual(duration(2 * 3_600 + 5 * 60), "2 h 5 min")
    }

    func testRevealSelectsTheOutermostAppBundle() {
        XCTAssertEqual(FinderReveal.path(forExecutable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
                       "/Applications/Visual Studio Code.app")
        XCTAssertEqual(FinderReveal.path(forExecutable: "/usr/local/bin/node"), "/usr/local/bin/node")
        XCTAssertNil(FinderReveal.path(forExecutable: ""))
    }

    private func incident(_ name: String, memory: UInt64, seenAt: TimeInterval, signature: ProcessSignature? = nil,
                          leak: Double = 0) -> RadarIncident {
        RadarIncident(
            signature: signature ?? ProcessSignature(displayName: name, canonicalPath: "/bin/\(name)", commandLine: name),
            familyName: name, level: .hot, maxScore: Double(memory), memoryBytes: memory, cpuPercent: 0,
            leakVelocityMegabytesPerMinute: leak, reasons: [], startedAt: now, lastSeenAt: now.addingTimeInterval(seenAt)
        )
    }
}
