import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Heavy mode tracks an app by what its helpers add up to. A browser or chat
/// app spreads its memory over many mid-size helpers: none clears the
/// per-process gate, yet together they are the heaviest thing on the Mac.
final class GroupInclusionTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private static let mib = Fixture.mib
    private static let chrome = "/Applications/Google Chrome.app/Contents"
    private static let helperPath = "\(chrome)/Frameworks/Google Chrome Framework.framework/Versions/126/Helpers"
        + "/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

    /// A main process at pid 100 and `helpers` renderers under it, all in one bundle.
    private func chromeTree(helpers: Int, helperMegabytes: Double, mainMegabytes: Double = 300) -> [ProcessMetrics] {
        let main = Fixture.process(pid: 100, name: "Google Chrome", path: "\(Self.chrome)/MacOS/Google Chrome",
                                   command: "\(Self.chrome)/MacOS/Google Chrome", megabytes: mainMegabytes)
        let renderers = (0..<helpers).map { index in
            Fixture.process(pid: 101 + Int32(index), parent: 100, name: "Google Chrome Helper (Renderer)", path: Self.helperPath,
                            command: "\(Self.helperPath) --type=renderer", megabytes: helperMegabytes)
        }
        return [main] + renderers
    }

    private func build(
        _ processes: [ProcessMetrics],
        mode: RadarMode = .heavy,
        groupFamilies: Bool = true,
        responsible: [ProcessIdentity: Int32] = [:]
    ) -> [ProcessFamily] {
        var settings = ThresholdSettings.smart
        settings.radarMode = mode
        settings.groupFamilies = groupFamilies
        var window = TrendWindow()
        return ProcessFamilyBuilder(currentUserID: 501)
            .buildFamilies(from: processes, settings: settings, trendWindow: &window, responsible: responsible, now: Fixture.now)
    }

    /// The same process owned by root.
    private func foreign(_ process: ProcessMetrics) -> ProcessMetrics {
        ProcessMetrics(
            identity: process.identity, parentPID: process.parentPID, userID: 0, ownerName: "root", name: process.name,
            executablePath: process.executablePath, commandLine: process.commandLine,
            residentMemoryBytes: process.residentMemoryBytes, physicalFootprintBytes: process.physicalFootprintBytes,
            virtualMemoryBytes: process.virtualMemoryBytes, cpuPercent: process.cpuPercent, totalProcessorSeconds: 0,
            threadCount: process.threadCount, isSystemProcess: false, sampledAt: process.sampledAt)
    }

    // MARK: - What joins

    func testHelpersThatAddUpToTheGateBecomeOneFamily() throws {
        // 300 MB + 20 x 200 MB: 4.2 GB against a 1 GiB limit, no process near 512 MiB.
        let families = build(chromeTree(helpers: 20, helperMegabytes: 200))
        XCTAssertEqual(families.count, 1)
        let family = try XCTUnwrap(families.first)
        XCTAssertEqual(family.root.pid, 100)
        XCTAssertEqual(family.members.count, 21)
        XCTAssertEqual(family.totalPhysicalFootprintBytes, 4_300 * Self.mib)
        XCTAssertEqual(family.displayName, "Google Chrome")
    }

    /// The gate is the per-process one, applied to the app: half the limit,
    /// inclusive, counted over the live members.
    func testTheGroupGateIsHalfTheLimitInclusive() {
        XCTAssertEqual(build(chromeTree(helpers: 3, helperMegabytes: 128, mainMegabytes: 128)).count, 1, "exactly 512 MiB")
        XCTAssertEqual(build(chromeTree(helpers: 3, helperMegabytes: 175, mainMegabytes: 175)).count, 1, "700 MB")
        XCTAssertTrue(build(chromeTree(helpers: 3, helperMegabytes: 127, mainMegabytes: 127)).isEmpty, "508 MiB")
        XCTAssertTrue(build(chromeTree(helpers: 3, helperMegabytes: 100, mainMegabytes: 100)).isEmpty, "400 MB")
    }

    /// A helper the per-process gate already tracks makes the app a family;
    /// the group rule must not add the same app a second time.
    func testAGroupWithAHeavyHelperIsOneFamily() throws {
        var processes = chromeTree(helpers: 6, helperMegabytes: 150)
        processes.append(Fixture.process(pid: 200, parent: 100, name: "Google Chrome Helper (GPU)", path: Self.helperPath,
                                         command: "\(Self.helperPath) --type=gpu-process", megabytes: 700))
        let families = build(processes)
        XCTAssertEqual(families.count, 1)
        let family = try XCTUnwrap(families.first)
        XCTAssertEqual(family.root.pid, 100)
        XCTAssertEqual(family.members.count, 8)
    }

    func testHelpersLinkedByTheirAppCountToo() throws {
        let safari = "/Applications/Safari.app/Contents/MacOS/Safari"
        let webKit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices"
        let app = Fixture.process(pid: 500, name: "Safari", path: safari, command: safari, megabytes: 200)
        let path = "\(webKit)/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let tabs = (0..<4).map { index in
            Fixture.process(pid: 510 + Int32(index), name: "com.apple.WebKit.WebContent", path: path, command: path, megabytes: 150)
        }
        let hints = Dictionary(uniqueKeysWithValues: tabs.map { ($0.identity, app.pid) })

        let families = build([app] + tabs, responsible: hints)
        XCTAssertEqual(families.count, 1, "800 MB across five processes, none over 512 MiB")
        XCTAssertEqual(families.first?.root.pid, 500)
        XCTAssertEqual(families.first?.members.count, 5)
        XCTAssertTrue(build([app] + tabs).isEmpty, "without the hints they are five separate processes")
    }

    // MARK: - What stays out

    /// Dev mode reads servers, runtimes and build tools, and looks at single
    /// processes only; the group rule is Heavy mode's.
    func testDevModeStillLooksAtSingleProcessesOnly() {
        let processes = chromeTree(helpers: 20, helperMegabytes: 200)
        XCTAssertTrue(build(processes, mode: .dev).isEmpty)
    }

    func testAllModeAndUngroupedFamiliesAreUnchanged() {
        let processes = chromeTree(helpers: 20, helperMegabytes: 200)
        XCTAssertEqual(build(processes, mode: .all).count, 1)
        XCTAssertEqual(build(processes, mode: .all).first?.members.count, 21)
        XCTAssertTrue(build(processes, groupFamilies: false).isEmpty, "with grouping off every process stands alone")
    }

    /// Children of one shell are not one app: nothing ties them together.
    func testUnrelatedChildrenOfAShellAreNotAGroup() {
        let shell = Fixture.process(pid: 50, name: "zsh", path: "/bin/zsh", command: "-zsh", megabytes: 10)
        let children = ["alpha", "beta", "gamma"].enumerated().map { index, name in
            Fixture.process(pid: 60 + Int32(index), parent: 50, name: name, path: "/opt/tools/\(name)/bin/\(name)",
                            command: "\(name) --serve", megabytes: 300)
        }
        XCTAssertTrue(build([shell] + children).isEmpty)
    }

    /// Another user's helpers can be neither measured nor stopped from here.
    func testAnotherUsersGroupIsNotTracked() {
        XCTAssertTrue(build(chromeTree(helpers: 20, helperMegabytes: 200).map(foreign)).isEmpty)
    }

    // MARK: - Stability

    /// Rules, snoozes and baselines follow the family key: it is the app's
    /// signature and root, never its helper count.
    func testTheFamilyKeyIgnoresHowManyHelpersAreOpen() throws {
        let many = try XCTUnwrap(build(chromeTree(helpers: 20, helperMegabytes: 200)).first)
        let fewer = try XCTUnwrap(build(chromeTree(helpers: 8, helperMegabytes: 200)).first)
        XCTAssertEqual(many.familyKey, fewer.familyKey)
        XCTAssertEqual(fewer.members.count, 9)
    }
}
