import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A finished scan that found nothing in scope is not a scan in progress:
/// the snapshot must say so, or the popover and Overview wait forever.
@MainActor
final class QuietScopeTests: XCTestCase {
    func testAFinishedScanWithNothingInScopeReadsAsQuietNotStarting() async {
        let monitor = ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501, processorCount: 8,
                                     physicalMemoryBytes: 16 << 30, directoryExists: { _ in true }),
                                     settings: .smart, store: nil)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        for tick in 0..<5 {
            await monitor.ingest(Self.lightApps(at: start.addingTimeInterval(Double(tick) * 3)), now: start.addingTimeInterval(Double(tick) * 3))
        }
        let compact = monitor.consoleSnapshot.compact
        XCTAssertTrue(compact.allRows.isEmpty, "light non-dev apps stay out of the Dev scope")
        XCTAssertGreaterThan(monitor.health.processCount, 0)
        XCTAssertTrue(compact.hasSampled)
        XCTAssertNotEqual(compact.commandCenter.statusText, "Starting scan")
        XCTAssertNotEqual(compact.intelligenceBrief.title, RadarIntelligenceBrief.empty.title)
        XCTAssertNotEqual(compact.intelligenceBrief.confidenceText, "Warming up")
    }

    func testBeforeTheFirstSampleTheSnapshotSaysItIsStarting() {
        let compact = CompactConsoleSnapshot.empty
        XCTAssertFalse(compact.hasSampled)
        XCTAssertEqual(compact.commandCenter.statusText, "Starting scan")
        XCTAssertFalse(compact.updatingEngineStatus(.empty, summary: .empty).hasSampled)
    }

    private static func lightApps(at now: Date) -> [ProcessMetrics] {
        func app(_ pid: Int32, _ name: String, _ path: String, megabytes: UInt64, cpu: Double) -> ProcessMetrics {
            ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: 1_999_990_000, startTimeMicroseconds: 0),
                           parentPID: 1, userID: 501, ownerName: "me", name: name, executablePath: path, commandLine: path,
                           residentMemoryBytes: megabytes << 20, physicalFootprintBytes: megabytes << 20,
                           virtualMemoryBytes: megabytes << 22, cpuPercent: cpu,
                           totalProcessorSeconds: cpu / 100 * now.timeIntervalSince1970.truncatingRemainder(dividingBy: 10_000),
                           threadCount: 8, isSystemProcess: false, sampledAt: now)
        }
        return [
            app(200, "Safari", "/Applications/Safari.app/Contents/MacOS/Safari", megabytes: 250, cpu: 2),
            app(300, "Mail", "/System/Applications/Mail.app/Contents/MacOS/Mail", megabytes: 200, cpu: 0.5),
            app(310, "Notes", "/System/Applications/Notes.app/Contents/MacOS/Notes", megabytes: 150, cpu: 0.3),
            app(320, "Music", "/System/Applications/Music.app/Contents/MacOS/Music", megabytes: 250, cpu: 2),
            app(400, "Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", megabytes: 120, cpu: 0.2),
        ]
    }
}
