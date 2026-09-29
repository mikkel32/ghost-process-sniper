import XCTest
@testable import GhostProcessSniperCore

/// Energy runs on every scan over the whole process table, so it must stay a
/// small slice of a tick.
final class EnergyCostTests: XCTestCase {
    func testASixHundredProcessScanStaysCheap() {
        var monitor = EnergyMonitor(battery: ScriptedBattery.discharging(watts: 12), assertions: ScriptedAssertions())
        func table(_ tick: Int, _ date: Date) -> [ProcessMetrics] {
            (0..<600).map { index in
                let app = index / 10
                return EnergyFixture.process(
                    pid: Int32(10_000 + index), name: "Helper \(index)",
                    path: "/Applications/App\(app).app/Contents/MacOS/Helper",
                    parent: index % 10 == 0 ? 1 : Int32(10_000 + app * 10),
                    counters: .init(joules: Double(tick * index) / 100, wakeups: UInt64(tick * index),
                                    diskBytes: UInt64(tick * 4_096), cpuSeconds: Double(tick) / 10),
                    at: date, watts: Double(index) / 1_000)
            }
        }
        let families = (0..<60).map { app in EnergyFixture.family(table(0, EnergyFixture.start).filter { $0.pid / 10 == 1_000 + app }) }
        var durations: [Double] = []
        var now = EnergyFixture.start
        for tick in 0..<40 {
            let processes = table(tick, now)
            let started = DispatchTime.now().uptimeNanoseconds
            _ = monitor.update(processes: processes, families: families, responsiblePIDs: [:], uiVisible: true, now: now)
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            now = now.addingTimeInterval(2)
        }
        let median = durations.sorted()[durations.count / 2]
        print("energy update median \(median) ms over \(durations.count) scans of 600 processes")
        // Debug builds are several times slower than release; this still guards against quadratic work.
        XCTAssertLessThan(median, 40)
    }
}
