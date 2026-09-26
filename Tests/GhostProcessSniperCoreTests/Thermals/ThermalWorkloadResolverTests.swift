import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ThermalWorkloadResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_200_000)

    func testBuildChildrenCollapseIntoOneJobNamedAfterItsRoot() throws {
        let processes = terminalShell() + [process(603, parent: 602, name: "make", path: "/usr/bin/make", cpu: 1)] +
            (0..<10).map { process(Int32(610 + $0), parent: 603, name: "clang", path: "/usr/bin/clang", cpu: 95) }
        let result = projection(processes)
        let job = try XCTUnwrap(result.contributors.first)
        XCTAssertEqual(result.contributors.count, 1)
        XCTAssertEqual(job.displayName, "make")
        XCTAssertEqual(job.kind, .job)
        XCTAssertEqual(job.hostAppName, "Terminal")
        XCTAssertEqual(job.processCount, 11)
        XCTAssertEqual(job.cpuCapacityPercent, 95.1, accuracy: 0.001)
        XCTAssertTrue(job.suggestedAction.contains("command-line job in Terminal"))
        XCTAssertEqual(job.workloadSummary, "Command-line job in Terminal · 11 processes")
        XCTAssertTrue(job.workloadExplanation.contains("started in Terminal"))

        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(92), activity: result, at: now)
        let insight = ThermalAppInsight.evaluate(activity: result, diagnosis: diagnosis, at: now)
        XCTAssertEqual(insight.title, "Start with make")
        XCTAssertTrue(insight.evidence.contains("95.1% of total CPU capacity"))
    }

    func testShortLivedCompilerChildrenKeepOneHistoryIdentity() {
        var history = ThermalActivityHistory()
        var current = ThermalActivitySummary.empty
        for (index, offset) in [0.0, 10, 25].enumerated() {
            let date = now.addingTimeInterval(offset)
            let clang = process(Int32(700 + index), parent: 603, name: "clang", path: "/usr/bin/clang", cpu: 180,
                                start: 2_000_199_000 + UInt64(offset), at: date)
            let summary = ThermalActivityAnalyzer.project(
                processes: terminalShell(at: date) + [process(603, parent: 602, name: "make", path: "/usr/bin/make", cpu: 1, at: date), clang],
                families: [], now: date, processorCount: 10)
            current = history.record(summary, at: date)
        }
        XCTAssertEqual(current.recentContributors.count, 1)
        XCTAssertEqual(current.recentContributors.first?.id, "job:603:2000199000.0")
        XCTAssertEqual(current.recentContributors.first?.activeSampleCount, 3)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(84, at: current.sampledAt), activity: current,
                                                  at: current.sampledAt)
        XCTAssertEqual(ThermalAppInsight.evaluate(activity: current, diagnosis: diagnosis, at: current.sampledAt)
            .evidenceStrength, .repeated)
    }

    func testHelpersWithUnresolvedPathsJoinTheirApplication() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let processes = [process(300, parent: 1, name: "Google Chrome", path: chrome, cpu: 20)] +
            (0..<12).map { process(Int32(400 + $0), parent: 300, name: "Google Chrome He", path: "", cpu: 9) }
        let result = projection(processes)
        XCTAssertEqual(result.contributors.count, 1)
        XCTAssertEqual(result.contributors.first?.displayName, "Google Chrome")
        XCTAssertEqual(result.contributors.first?.kind, .app)
        XCTAssertEqual(result.contributors.first?.processCount, 13)
        XCTAssertEqual(result.contributors.first?.cpuPercent ?? 0, 128, accuracy: 0.001)
        XCTAssertEqual(result.contributors.first?.applicationPath, "/Applications/Google Chrome.app")
    }

    func testEditorExtensionHostWorkBelongsToTheEditor() {
        let result = projection(editor() + [process(502, parent: 501, name: "node", path: "/opt/homebrew/bin/node", cpu: 150)])
        XCTAssertEqual(result.contributors.map(\.displayName), ["Visual Studio Code"])
        XCTAssertEqual(result.contributors.first?.processCount, 3)
    }

    func testJobInAnEditorsIntegratedTerminalIsNotBlamedOnTheEditor() {
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        let result = projection(editor() + [
            process(503, parent: 500, name: "Code Helper", path: helper, cpu: 1),
            process(504, parent: 503, name: "zsh", path: "/bin/zsh", cpu: 0),
            process(505, parent: 504, name: "node", path: "/opt/homebrew/bin/node", cpu: 150)
        ])
        let node = result.contributors.first { $0.displayName == "node" }
        XCTAssertEqual(node?.id, "job:505:2000199000.0")
        XCTAssertEqual(node?.kind, .job)
        XCTAssertNil(node?.hostAppName, "An editor is not a terminal host")
        XCTAssertEqual(result.contributors.first { $0.displayName == "Visual Studio Code" }?.cpuPercent, 8)
    }

    func testTmuxIsAJobBoundary() {
        let result = projection([
            process(800, parent: 1, name: "tmux", path: "/opt/homebrew/bin/tmux", cpu: 0),
            process(801, parent: 800, name: "zsh", path: "/bin/zsh", cpu: 0),
            process(802, parent: 801, name: "python3", path: "/usr/bin/python3", cpu: 90),
            process(803, parent: 800, name: "htop", path: "/opt/homebrew/bin/htop", cpu: 60)
        ])
        XCTAssertEqual(Set(result.contributors.map(\.id)), ["job:802:2000199000.0", "job:803:2000199000.0"])
        XCTAssertTrue(result.contributors.allSatisfy { $0.hostAppName == nil })
    }

    func testRecycledParentPIDIsNotFollowed() {
        var resolver = ThermalWorkloadResolver(processes: [
            process(900, parent: 1, name: "Editor", path: "/Applications/Editor.app/Contents/MacOS/Editor", cpu: 0,
                    start: 2_000_199_500),
            process(901, parent: 900, name: "worker", path: "/usr/local/bin/worker", cpu: 50, start: 2_000_199_000)
        ])
        let assignment = resolver.assignment(for: process(901, parent: 900, name: "worker", path: "/usr/local/bin/worker",
                                                          cpu: 50, start: 2_000_199_000))
        XCTAssertEqual(assignment.groupKey, "job:901:2000199000.0")
        XCTAssertEqual(assignment.kind, .process)
    }

    func testCyclesAndDeepChainsTerminateWithinTheHopLimit() {
        let loop = [process(20, parent: 21, name: "a", path: "/bin/a", cpu: 10),
                    process(21, parent: 20, name: "b", path: "/bin/b", cpu: 10)]
        var resolver = ThermalWorkloadResolver(processes: loop)
        XCTAssertEqual(resolver.assignment(for: loop[0]).groupKey, "job:21:2000199000.0")
        XCTAssertLessThanOrEqual(resolver.visitedHops, 1)

        let chain = [process(1000, parent: 1, name: "App", path: "/Applications/Deep.app/Contents/MacOS/Deep", cpu: 0)] +
            (1...40).map { process(Int32(1000 + $0), parent: Int32(999 + $0), name: "step", path: "/bin/step", cpu: 1) }
        var deep = ThermalWorkloadResolver(processes: chain)
        let assignment = deep.assignment(for: chain[40])
        XCTAssertEqual(assignment.groupKey, "job:1024:2000199000.0", "Stops after 16 hops, far below the app")
        XCTAssertEqual(deep.visitedHops, ThermalWorkloadResolver.maximumHops)
    }

    func testHiddenHeatSourcesAreLabelledAndSystemFramed() throws {
        let vm = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        let result = projection([
            process(50, parent: 1, name: "com.apple.Virtualization.Virtua", path: vm, cpu: 400),
            process(51, parent: 1, name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores", cpu: 60),
            process(52, parent: 1, name: "mdworker_shared", path: "", cpu: 30),
            process(53, parent: 1, name: "WindowServer", path: "", cpu: 40)
        ])
        let machine = try XCTUnwrap(result.contributors.first { $0.knownSource == .virtualMachine })
        XCTAssertEqual(machine.displayName, "Linux virtual machine")
        XCTAssertTrue(ThermalKnownSource.virtualMachine.label.contains("Docker Desktop"))
        XCTAssertTrue(machine.isSystemProcess, "Known sources are never framed as apps to stop")
        XCTAssertEqual(machine.suggestedAction, ThermalKnownSource.virtualMachine.advice)
        XCTAssertEqual(machine.workloadSummary, "Docker Desktop, colima, OrbStack, Lima or UTM")
        let spotlight = try XCTUnwrap(result.contributors.first { $0.knownSource == .spotlight })
        XCTAssertEqual(spotlight.displayName, "Spotlight indexing")
        XCTAssertEqual(spotlight.processCount, 2)
        XCTAssertEqual(spotlight.workloadSummary, "macOS background work")
        XCTAssertEqual(result.contributors.first { $0.knownSource == .windowServer }?.displayName, "Screen drawing")
        XCTAssertNil(ThermalKnownSource.matching(name: "com.apple.Virtua", executablePath: ""), "Too short to be unambiguous")
    }

    func testProjectionDoesNotDependOnInputOrder() {
        let processes = terminalShell() + editor() + [
            process(603, parent: 602, name: "make", path: "/usr/bin/make", cpu: 3),
            process(610, parent: 603, name: "clang", path: "/usr/bin/clang", cpu: 80),
            process(502, parent: 501, name: "node", path: "/opt/homebrew/bin/node", cpu: 40)
        ]
        XCTAssertEqual(projection(processes), projection(processes.reversed()))
        XCTAssertEqual(projection(processes), projection(processes.sorted { $0.name < $1.name }))
    }

    func testLargeInventoryResolvesInLinearHops() {
        // A single deep chain is the worst case for walking parents.
        let processes = (0..<2_000).map { (index: Int) -> ProcessMetrics in
            let pid = Int32(10_000 + index)
            return process(pid, parent: index == 0 ? 1 : pid - 1, name: "step-\(index)", path: "/bin/step", cpu: 1)
        }
        var resolver = ThermalWorkloadResolver(processes: processes)
        for process in processes { _ = resolver.assignment(for: process) }
        XCTAssertLessThanOrEqual(resolver.visitedHops, processes.count * ThermalWorkloadResolver.maximumHops)
        let before = resolver.visitedHops
        for process in processes { _ = resolver.assignment(for: process) }
        XCTAssertEqual(resolver.visitedHops, before, "Repeated lookups are memoized")
        XCTAssertEqual(projection(processes).observedProcessCount, 2_000)
    }

    private func projection(_ processes: [ProcessMetrics]) -> ThermalActivitySummary {
        ThermalActivityAnalyzer.project(processes: processes, families: [], now: now, processorCount: 10)
    }

    private func terminalShell(at date: Date? = nil) -> [ProcessMetrics] {
        [process(600, parent: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", cpu: 0, at: date),
         process(601, parent: 600, name: "login", path: "/usr/bin/login", cpu: 0, at: date),
         process(602, parent: 601, name: "-zsh", path: "/bin/zsh", cpu: 0, at: date)]
    }

    private func editor() -> [ProcessMetrics] {
        let app = "/Applications/Visual Studio Code.app"
        return [process(500, parent: 1, name: "Electron", path: "\(app)/Contents/MacOS/Electron", cpu: 5),
                process(501, parent: 500, name: "Code Helper (Plugin)",
                        path: "\(app)/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", cpu: 2)]
    }

    private func snapshot(_ celsius: Double, at date: Date? = nil) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: date ?? now, cpuCelsius: celsius, gpuCelsius: nil, sensorCount: 1,
                        sensorKeys: [], systemState: "Nominal", unavailableReason: nil)
    }

    private func process(_ pid: Int32, parent: Int32, name: String, path: String, cpu: Double,
                         start: UInt64 = 2_000_199_000, at date: Date? = nil) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
            parentPID: parent, userID: 501, ownerName: "fixture", name: name, executablePath: path,
            commandLine: name, residentMemoryBytes: 1, physicalFootprintBytes: 1, virtualMemoryBytes: 1,
            cpuPercent: cpu, totalProcessorSeconds: 1, threadCount: 1, isSystemProcess: false,
            sampledAt: date ?? now)
    }
}
