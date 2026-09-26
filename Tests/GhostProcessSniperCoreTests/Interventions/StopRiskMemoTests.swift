import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Stop risk is shown on every family page render; it must be assessed once
/// per membership change, and cheaply even for Electron-sized argv.
final class StopRiskMemoTests: XCTestCase {
    func testSecondCallIsAMemoHit() {
        let family = Self.electronFamily()
        var cache = StopRiskCache()
        let first = cache.entry(for: family, sample: family.members, revision: 1, liveFamilyKeys: [family.familyKey])
        let second = cache.entry(for: family, sample: family.members, revision: 1, liveFamilyKeys: [family.familyKey])
        XCTAssertEqual(cache.assessmentCount, 1)
        XCTAssertEqual(first.risk, second.risk)
        XCTAssertEqual(first.risk.kind, .editor)
    }

    func testNewSampleWithSameMembersKeepsTheMemo() {
        let family = Self.electronFamily()
        var cache = StopRiskCache()
        _ = cache.entry(for: family, sample: family.members, revision: 1, liveFamilyKeys: [family.familyKey])
        let busier = Self.electronFamily(cpu: 80)
        let entry = cache.entry(for: busier, sample: busier.members, revision: 2, liveFamilyKeys: [busier.familyKey])
        XCTAssertEqual(cache.assessmentCount, 1, "metrics change every refresh; identities do not")
        XCTAssertEqual(entry.workload.root?.cpuPercent, 80, "the reclaim estimate reads the latest radar numbers")
        XCTAssertEqual(entry.workload.processes.map(\.cpuPercent), Array(repeating: 80, count: busier.members.count))
    }

    func testMembershipChangeRecomputes() {
        let family = Self.electronFamily()
        var cache = StopRiskCache()
        _ = cache.entry(for: family, sample: family.members, revision: 1, liveFamilyKeys: [family.familyKey])
        let grown = Self.electronFamily(helpers: 41)
        _ = cache.entry(for: grown, sample: grown.members, revision: 2, liveFamilyKeys: [grown.familyKey])
        XCTAssertEqual(cache.assessmentCount, 2)
    }

    func testFamiliesThatLeaveAreEvicted() {
        let family = Self.electronFamily()
        let other = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(1))
        var cache = StopRiskCache()
        _ = cache.entry(for: family, sample: family.members, revision: 1, liveFamilyKeys: [family.familyKey, other.familyKey])
        _ = cache.entry(for: other, sample: [other.root], revision: 1, liveFamilyKeys: [family.familyKey, other.familyKey])
        XCTAssertEqual(cache.entryCount, 2)
        _ = cache.entry(for: other, sample: [other.root], revision: 2, liveFamilyKeys: [other.familyKey])
        XCTAssertEqual(cache.entryCount, 1)
    }

    func testDescendantOfAnotherFamilyIsPartOfTheMemo() {
        let runner = Self.process(1500, name: "node", path: "/usr/local/bin/node", command: "node /usr/local/bin/foreman start", cpu: 5)
        let postgres = Self.process(1501, parent: 1500, name: "postgres", path: "/opt/homebrew/bin/postgres",
                                    command: KillFixture.postgresCommand, cpu: 5)
        // The radar gave postgres a family of its own; the stop still hits it.
        let family = RefreshPerformanceFixture.family(runner, members: [runner])
        var cache = StopRiskCache()

        let alone = cache.entry(for: family, sample: [runner], revision: 1, liveFamilyKeys: [family.familyKey])
        let withDatabase = cache.entry(for: family, sample: [runner, postgres], revision: 2, liveFamilyKeys: [family.familyKey])

        XCTAssertNotEqual(alone.risk.kind, .dataStore)
        XCTAssertEqual(withDatabase.risk.kind, .dataStore, "a database started under the runner changes what stopping it risks")
        XCTAssertEqual(cache.assessmentCount, 2)
    }

    func testFamilyGhostRunsInsideIsBlocked() {
        let family = Self.electronFamily()
        // Ghost was started from the family's first helper, as from a terminal.
        let ghost = Self.process(990, parent: 901, name: "GhostProcessSniper", path: "/tmp/GhostProcessSniper",
                                 command: "/tmp/GhostProcessSniper", cpu: 1)
        var guarded = StopRiskCache(protection: KillProtectionPolicy(selfPID: 990))
        var elsewhere = StopRiskCache(protection: KillProtectionPolicy(selfPID: 4_000))

        let blocked = guarded.entry(for: family, sample: family.members + [ghost], revision: 1, liveFamilyKeys: [family.familyKey])
        let free = elsewhere.entry(for: family, sample: family.members, revision: 1, liveFamilyKeys: [family.familyKey])

        XCTAssertEqual(blocked.blockedReason, "Ghost runs inside Electron; stopping it would stop Ghost mid-way.")
        XCTAssertNil(free.blockedReason)
    }

    @MainActor
    func testMonitorPageAndPlanShareOneAssessment() async {
        let monitor = ProcessMonitor(builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        let family = Self.electronFamily()
        let risk = monitor.stopRisk(for: family)
        let plan = await monitor.killPlan(for: family)
        XCTAssertEqual(KillRiskAssessor().assess(plan.workload ?? .empty), risk)
        XCTAssertEqual(monitor.stopRiskCache.assessmentCount, 1)
    }

    @MainActor
    func testPlanWorkloadFollowsTheLatestSample() async {
        let monitor = ProcessMonitor(builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        let idle = Self.electronFamily(cpu: 5)
        await monitor.ingest(idle.members)
        _ = monitor.stopRisk(for: idle)
        _ = await monitor.killPlan(for: idle)

        let runaway = Self.electronFamily(cpu: 300)
        await monitor.ingest(runaway.members)
        let plan = await monitor.killPlan(for: runaway)

        XCTAssertEqual(plan.workload?.root?.cpuPercent, 300, "a preview after a spike must not show the idle scan's CPU")
        XCTAssertEqual(monitor.stopRiskCache.assessmentCount, 1)
    }

    func testLongArgvAssessmentStaysCheap() {
        let workload = KillWorkloadProfile(family: Self.electronFamily(), sample: [])
        let assessor = KillRiskAssessor()
        _ = assessor.assess(workload)
        let runs = 5
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<runs {
            _ = assessor.assess(workload)
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 / Double(runs)
        // Release builds take well under 3 ms; the bound leaves room for
        // unoptimized test builds while still catching full-argv scans.
        XCTAssertLessThan(milliseconds, 25, "assessing a 41-member family took \(milliseconds) ms")
    }

    // MARK: - Fixtures

    /// A VS Code-like family: the app and helpers with about 5 KB of argv each.
    static func electronFamily(helpers: Int = 40, cpu: Double = 5) -> ProcessFamily {
        let app = "/Applications/Visual Studio Code.app"
        let flags = (0..<190).map { "--enable-feature-\($0)=true" }.joined(separator: " ")
        let root = process(900, name: "Electron", path: "\(app)/Contents/MacOS/Electron", command: "\(app)/Contents/MacOS/Electron \(flags)", cpu: cpu)
        let helperPath = "\(app)/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)"
        let members = (0..<helpers).map { index in
            process(Int32(901 + index), parent: 900, name: "Code Helper (Renderer)", path: helperPath,
                    command: "\(helperPath) --type=renderer \(flags)", cpu: cpu)
        }
        return RefreshPerformanceFixture.family(root, members: [root] + members)
    }

    private static func process(_ pid: Int32, parent: Int32 = 1, name: String, path: String, command: String, cpu: Double) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_000, startTimeMicroseconds: 0),
            parentPID: parent, userID: 501, ownerName: "me", name: name, executablePath: path, commandLine: command,
            residentMemoryBytes: 100_000_000, physicalFootprintBytes: 100_000_000, virtualMemoryBytes: 200_000_000,
            cpuPercent: cpu, totalProcessorSeconds: 10, threadCount: 4, isSystemProcess: false, sampledAt: Date()
        )
    }
}
