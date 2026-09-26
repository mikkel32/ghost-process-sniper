import XCTest
@testable import GhostProcessSniperCore

final class RadarSnapshotDifferTests: XCTestCase {
    private typealias Fixture = RefreshPerformanceFixture

    func testReportsOnlyNewAndChangedIdentities() {
        var differ = RadarSnapshotDiffer()
        let steady = Fixture.process(0)
        let growing = Fixture.process(1)
        XCTAssertEqual(differ.update(with: [steady, growing]).changedOrAdded,
            [steady.identity, growing.identity])

        let grown = with(growing, memory: growing.physicalFootprintBytes + 64 * 1_048_576)
        let newcomer = Fixture.process(2)
        XCTAssertEqual(differ.update(with: [steady, grown, newcomer]).changedOrAdded,
            [grown.identity, newcomer.identity])
        XCTAssertTrue(differ.update(with: [steady, grown, newcomer]).changedOrAdded.isEmpty)
    }

    func testCommandLineAloneIsNotAMetricChange() {
        var differ = RadarSnapshotDiffer()
        let process = Fixture.process(0)
        _ = differ.update(with: [process])
        XCTAssertTrue(differ.update(with: [with(process, commandLine: "tool-0 --other")]).changedOrAdded.isEmpty)
    }

    private func with(_ process: ProcessMetrics, memory: UInt64? = nil, commandLine: String? = nil) -> ProcessMetrics {
        ProcessMetrics(identity: process.identity, parentPID: process.parentPID, userID: process.userID,
            ownerName: process.ownerName, name: process.name, executablePath: process.executablePath,
            commandLine: commandLine ?? process.commandLine,
            residentMemoryBytes: memory ?? process.residentMemoryBytes,
            physicalFootprintBytes: memory ?? process.physicalFootprintBytes,
            virtualMemoryBytes: process.virtualMemoryBytes, cpuPercent: process.cpuPercent,
            totalProcessorSeconds: process.totalProcessorSeconds, threadCount: process.threadCount,
            isSystemProcess: process.isSystemProcess, sampledAt: process.sampledAt)
    }
}
