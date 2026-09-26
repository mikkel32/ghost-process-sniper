import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Pins what a faster pipeline must not change: signature ids and
/// membership key persisted baselines, incidents and rules, and component
/// text is what fixed0/fixed1 print. The per-tick cost work was checked
/// byte-identical against the pre-refactor pipeline over these fixtures.
/// Update a digest only for an intended change; set GOLDEN_DUMP to a
/// directory to write the lines for a diff.
final class PipelineGoldenTests: XCTestCase {
    private static let signatureDigest = "574dbf7d8fe1adb5"
    private static let componentDigest = "81222adcc2981d55"

    func testSignatureIDsAndMembershipAreUnchanged() throws {
        let lines = Self.families().map { "\($0.signature.id) \($0.members.map(\.pid).sorted())" }
        XCTAssertGreaterThan(lines.count, 200)
        try Self.dump(lines, name: "signatures")
        XCTAssertEqual(Self.digest(lines), Self.signatureDigest, "\(lines.count) lines")
    }

    func testComponentTextIsUnchanged() throws {
        let lines = Self.families().flatMap { family in
            family.score.components.map { "\(family.signature.id) \($0.slot)|\($0.title)|\($0.detail)" }
        }
        XCTAssertGreaterThan(lines.count, 500)
        try Self.dump(lines, name: "components")
        XCTAssertEqual(Self.digest(lines), Self.componentDigest, "\(lines.count) lines")
    }

    /// Six ticks of the developer Mac, then the refresh fixture, on a fixed
    /// 8-core, 32 GB host whatever machine runs the test.
    private static func families() -> [ProcessFamily] {
        var settings = ThresholdSettings.smart
        settings.radarMode = .all
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: RadarRule.builtIns(settings: settings))
        func pipeline() -> RadarPipeline {
            RadarPipeline(
                builder: ProcessFamilyBuilder(currentUserID: DevWorkstationFixture.user, processorCount: 8,
                                              physicalMemoryBytes: 32 << 30, directoryExists: { _ in true }),
                intelligence: RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: 8, physicalMemoryBytes: 32 << 30))
            )
        }
        var dev = pipeline()
        var families: [ProcessFamily] = []
        for tick in 0..<6 {
            families = dev.run(processes: DevWorkstationFixture.processes(count: 600, tick: tick), settings: settings,
                               context: context, now: DevWorkstationFixture.date(tick: tick)).families
        }
        var refresh = pipeline()
        families += refresh.run(processes: (0..<200).map { RefreshPerformanceFixture.process($0) }, settings: settings,
                                context: context, now: RefreshPerformanceFixture.now).families
        return families.sorted { ($0.signature.id, $0.root.pid) < ($1.signature.id, $1.root.pid) }
    }

    /// FNV-1a: stable across runs and platforms, unlike Hasher.
    private static func digest(_ lines: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lines.joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func dump(_ lines: [String], name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["GOLDEN_DUMP"] else { return }
        try lines.joined(separator: "\n").write(toFile: "\(directory)/\(name).txt", atomically: true, encoding: .utf8)
    }
}
