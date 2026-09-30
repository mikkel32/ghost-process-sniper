import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// An All Processes row says why the family has its status, and that a
/// family is several processes: a 1.7 GB app reads as a group, not as one
/// process that is oddly big.
final class ProcessBrowserRowReasonTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let app = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    private let squeezed = SystemMemoryPressure(level: .warning, usedFraction: 0.92, totalBytes: 16 << 30,
                                                availableBytes: 1 << 30, compressedBytes: 4 << 30)

    private func browserRow(_ family: ProcessFamily, match: ProcessSearchMatch? = nil) -> ProcessBrowserRowModel {
        ProcessBrowserRowModel(family: FamilyTriageViewModel(family: family), match: match,
                               executablePath: family.root.executablePath, commandLine: family.root.commandLine)
    }

    /// ChatGPT's main process and two helpers: 1.7 GB in all, with the Mac short of memory.
    private func chatGPT() throws -> ProcessFamily {
        let root = Fixture.process(pid: 11_850, name: "ChatGPT", path: app, command: app, megabytes: 1_000, cpu: 2)
        let helpers = (1...2).map {
            Fixture.process(pid: 11_850 + Int32($0), parent: 11_850, name: "ChatGPT Helper",
                            path: "\(app) Helper", command: "\(app) Helper", megabytes: 350, cpu: 1)
        }
        var window = TrendWindow()
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [], systemPressure: squeezed)
        return try XCTUnwrap(Fixture.scored([root] + helpers, context: context, window: &window).first { $0.root.pid == 11_850 })
    }

    func testARowSaysHowManyProcessesTheFamilyHoldsAndWhy() throws {
        let family = try chatGPT()
        XCTAssertEqual(family.members.count, 3)
        XCTAssertEqual(browserRow(family).detail, "3 processes · Holds 11% of scarce memory")
    }

    func testALoneProcessIsNotCountedAsAGroup() throws {
        let root = Fixture.process(pid: 5_100, megabytes: 40, cpu: 1)
        let row = browserRow(Fixture.family(root, level: .quiet))
        XCTAssertEqual(row.detail, "Within observed limits")
    }

    func testAQuietFamilyKeepsItsCauseAfterTheCount() {
        let root = Fixture.process(pid: 5_200, megabytes: 40, cpu: 1)
        let helper = Fixture.process(pid: 5_201, parent: 5_200, megabytes: 40, cpu: 1)
        let row = browserRow(Fixture.family(root, members: [root, helper], level: .quiet))
        XCTAssertEqual(row.detail, "2 processes · Within observed limits")
    }

    /// What matched a search is what the user asked about: it replaces the reason.
    func testASearchMatchStillOverridesTheReason() throws {
        let match = ProcessSearchMatch(score: 1, nameHighlights: [], reason: "Command contains \"helper\"")
        XCTAssertEqual(browserRow(try chatGPT(), match: match).detail, "Command contains \"helper\"")
    }
}
