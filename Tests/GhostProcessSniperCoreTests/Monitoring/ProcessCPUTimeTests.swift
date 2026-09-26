import Darwin
import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ProcessCPUTimeTests: XCTestCase {
    func testAppleSiliconTicksBecomeSecondsBeforeCalculatingLoad() {
        let seconds = ProcessCPUTime.seconds(user: 18_000_000, system: 6_000_000,
                                            numerator: 125, denominator: 3)
        XCTAssertEqual(seconds, 1, accuracy: 0.000001)
        var tracker = CPUUsageTracker<Int>()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(tracker.percent(key: 1, totalProcessorSeconds: 0, wallClock: start))
        XCTAssertEqual(tracker.percent(key: 1, totalProcessorSeconds: seconds,
            wallClock: start.addingTimeInterval(1)) ?? -1, 100, accuracy: 0.001)
    }

    func testIntelTimebaseAndLargeCounters() {
        XCTAssertEqual(ProcessCPUTime.seconds(user: 750_000_000, system: 250_000_000,
            numerator: 1, denominator: 1), 1, accuracy: 0.000001)
        XCTAssertTrue(ProcessCPUTime.seconds(user: .max, system: .max,
            numerator: 125, denominator: 3).isFinite)
    }

    func testInvalidClockDoesNotPoisonFollowingMeasurements() {
        XCTAssertTrue(ProcessCPUTime.seconds(user: 1, system: 1, numerator: 1, denominator: 0).isNaN)
        var tracker = CPUUsageTracker<Int>()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(tracker.percent(key: 1, totalProcessorSeconds: 0, wallClock: start))
        XCTAssertNil(tracker.percent(key: 1, totalProcessorSeconds: .nan, wallClock: start.addingTimeInterval(1)))
        XCTAssertEqual(tracker.percent(key: 1, totalProcessorSeconds: 2,
            wallClock: start.addingTimeInterval(2)) ?? -1, 100, accuracy: 0.001)
    }

    func testNativeTaskInfoConversionMatchesPOSIXCPUClock() throws {
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        XCTAssertEqual(proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size), size)
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        let seconds = ProcessCPUTime.seconds(user: info.pti_total_user, system: info.pti_total_system)
        XCTAssertGreaterThanOrEqual(seconds, cpuSeconds(before) - 0.02)
        XCTAssertLessThanOrEqual(seconds, cpuSeconds(after) + 0.02)
    }

    func testNativeRusageConversionMatchesPOSIXCPUClock() throws {
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        XCTAssertEqual(result, 0)
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        let seconds = ProcessCPUTime.seconds(user: usage.ri_user_time, system: usage.ri_system_time)
        XCTAssertGreaterThanOrEqual(seconds, cpuSeconds(before) - 0.02)
        XCTAssertLessThanOrEqual(seconds, cpuSeconds(after) + 0.02)
    }

    func testGPUCounterDoesNotCrossRecycledPID() {
        var tracker = ProcessGPUUsageTracker()
        let first = ProcessIdentity(pid: 42, startTimeSeconds: 100, startTimeMicroseconds: 0)
        let replacement = ProcessIdentity(pid: 42, startTimeSeconds: 200, startTimeMicroseconds: 0)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(tracker.update(rawNanosecondsByPID: [42: 100_000_000], now: start,
            identitiesByPID: [42: first]).isEmpty)
        XCTAssertEqual(tracker.update(rawNanosecondsByPID: [42: 600_000_000],
            now: start.addingTimeInterval(1), identitiesByPID: [42: first])[42] ?? -1, 50, accuracy: 0.001)
        XCTAssertTrue(tracker.update(rawNanosecondsByPID: [42: 700_000_000],
            now: start.addingTimeInterval(2), identitiesByPID: [42: replacement]).isEmpty)
        XCTAssertEqual(tracker.update(rawNanosecondsByPID: [42: 800_000_000],
            now: start.addingTimeInterval(3), identitiesByPID: [42: replacement])[42] ?? -1, 10, accuracy: 0.001)
    }

    func testResourceDatesCanDifferFromFreshMemoryProbe() {
        let now = Date(timeIntervalSince1970: 1_000)
        let priorGPU = now.addingTimeInterval(-8)
        let process = ProcessMetrics(
            identity: ProcessIdentity(pid: 42, startTimeSeconds: 100, startTimeMicroseconds: 0),
            parentPID: 1, userID: 501, ownerName: "fixture", name: "Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example", commandLine: "Example",
            residentMemoryBytes: 100, physicalFootprintBytes: 100, virtualMemoryBytes: 100,
            cpuPercent: 0, gpuUsagePercent: 30, totalProcessorSeconds: 0, threadCount: 1,
            isSystemProcess: false, sampledAt: now, measurementStatus: .fresh,
            cpuMeasurementStatus: .unavailable, gpuMeasurementStatus: .cached(priorGPU)
        )
        XCTAssertEqual(process.measurementDate, now)
        XCTAssertNil(process.cpuMeasurementDate)
        XCTAssertEqual(process.gpuMeasurementDate, priorGPU)
    }

    private func cpuSeconds(_ value: rusage) -> Double {
        Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) +
            Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
}
