import XCTest
@testable import GhostProcessSniperCore

final class PowerReadingTests: XCTestCase {
    func testTheSamplerTurnsLifetimeCountersIntoRates() async throws {
        let source = FakeProbeSource([FakeProbeSource.Process(pid: 900, name: "render")])
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: .fixture(at: 0))
        let first = try await sampler.sample(plan: .fixture(at: 0))
        XCTAssertNil(first.processes.first?.power.watts, "no interval yet at the same clock")
        source.advance(seconds: 4)
        source.update(pid: 900) {
            $0.energyNanojoules += 10_000_000_000
            $0.idleWakeups += 800
            $0.diskBytesWritten += 4_000_000
        }
        let batch = try await sampler.sample(plan: .fixture(at: 4))
        let power = try XCTUnwrap(batch.processes.first?.power)
        XCTAssertEqual(power.watts ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(power.idleWakeupsPerSecond ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(power.diskWriteBytesPerSecond ?? 0, 1_000_000, accuracy: 1e-6)
        XCTAssertEqual(power.lifetimeEnergyNanojoules, 10_000_000_000)
        XCTAssertEqual(power.measuredAt, batch.sampledAt)
    }

    func testAReusedPIDNeverBorrowsCounters() {
        var tracker = PowerCounterTracker()
        let key = ProcessIdentity(pid: 5, startTimeSeconds: 1, startTimeMicroseconds: 0)
        let now = Date()
        func reading(_ energy: UInt64, at seconds: UInt64, stamp: UInt64) -> ProbeUsage {
            ProbeUsage(cpuSeconds: 0, physicalFootprintBytes: 0, residentBytes: 0, idleWakeups: 0, diskBytesWritten: 0,
                       energyNanojoules: energy, processStartAbsoluteTime: stamp,
                       sampledAtUptimeNanoseconds: seconds * 1_000_000_000)
        }
        _ = tracker.usage(for: key, reading: reading(1_000_000_000, at: 10, stamp: 7), at: now)
        XCTAssertNil(tracker.usage(for: key, reading: reading(9_000_000_000, at: 12, stamp: 8), at: now).watts)
        let backwards = tracker.usage(for: key, reading: reading(1, at: 14, stamp: 8), at: now)
        XCTAssertNil(backwards.watts, "a counter that went backwards is not negative work")
        XCTAssertEqual(tracker.usage(for: key, reading: reading(2_000_000_001, at: 16, stamp: 8), at: now).watts ?? 0,
                       1, accuracy: 1e-9)
    }

    func testBatteryFiguresComeFromRawCapacityAndVoltage() {
        var reading = BatteryReading(
            hasBattery: true, onExternalPower: false, isCharging: false, chargePercent: 71,
            currentCapacityMilliampHours: 4_305, fullChargeCapacityMilliampHours: 4_340,
            designCapacityMilliampHours: 6_075, voltageMillivolts: 12_597, amperageMilliamps: -1_000,
            systemLoadWatts: 18.6, readAt: Date())
        XCTAssertEqual(reading.remainingWattHours ?? 0, 54.23, accuracy: 0.01)
        XCTAssertEqual(reading.healthPercent ?? 0, 71.44, accuracy: 0.01)
        XCTAssertEqual(reading.drawWatts ?? 0, 12.597, accuracy: 0.001, "discharging: amperage times voltage")
        reading.batteryDischargeWatts = 14
        XCTAssertEqual(reading.drawWatts, 14, "the power controller's own figure wins")
        reading.onExternalPower = true
        XCTAssertEqual(reading.drawWatts, 18.6, "on the charger: the system load")
        XCTAssertNil(BatteryReading.none.drawWatts)
    }

    func testPowerAssertionsKeepOnlyWhatHoldsTheMacOrDisplayAwake() {
        let started = Date(timeIntervalSince1970: 1_000)
        let audio = SleepAssertion.parse(pid: 413, entry: [
            "AssertType": "PreventUserIdleSystemSleep", "AssertLevel": NSNumber(value: 255),
            "AssertName": "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep",
            "AssertStartWhen": started, "AssertionOnBehalfOfPID": NSNumber(value: 44_399), "Process Name": "coreaudiod"
        ])
        XCTAssertEqual(audio?.effect, .systemSleep)
        XCTAssertEqual(audio?.responsiblePID, 44_399)
        XCTAssertTrue(audio?.isAudio ?? false)
        XCTAssertEqual(audio?.startedAt, started)

        let display = SleepAssertion.parse(pid: 9, entry: ["AssertType": "NoDisplaySleepAssertion", "AssertLevel": NSNumber(value: 255)])
        XCTAssertEqual(display?.effect, .displaySleep)
        XCTAssertNil(SleepAssertion.parse(pid: 9, entry: ["AssertType": "BackgroundTask", "AssertLevel": NSNumber(value: 255)]))
        XCTAssertNil(SleepAssertion.parse(pid: 9, entry: ["AssertType": "PreventSystemSleep", "AssertLevel": NSNumber(value: 0)]),
                     "released")
        let own = SleepAssertion.parse(pid: 9, entry: ["AssertType": "PreventSystemSleep", "AssertionOnBehalfOfPID": NSNumber(value: 9)])
        XCTAssertNil(own?.onBehalfOfPID)
    }

    func testSleepReasonsReadPlainly() {
        func reason(_ name: String, _ effect: SleepAssertionEffect = .systemSleep) -> String {
            EnergyReportBuilder.reason(for: SleepAssertion(pid: 1, processName: "x", type: "PreventUserIdleSystemSleep",
                                                           effect: effect, name: name, startedAt: nil))
        }
        XCTAssertEqual(reason("com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"), "An audio stream is open")
        XCTAssertEqual(reason("com.apple.audio.AVVCAggregateDevice-1355.context.preventuseridlesleep"),
                       "An audio recording or call is open")
        XCTAssertEqual(reason("NSURLSessionTask F69B16F1"), "Finishing a download or upload")
        XCTAssertEqual(reason("Electron"), "Asked macOS not to sleep")
        XCTAssertEqual(reason("", .displaySleep), "Asked macOS to keep the display on")
        XCTAssertEqual(reason("Xcode running tests."), "\u{201c}Xcode running tests.\u{201d}")
    }

    func testDurationsAndAmountsReadNaturally() {
        XCTAssertEqual(EnergyFormat.duration(40), "40 s")
        XCTAssertEqual(EnergyFormat.duration(45 * 60), "45 min")
        XCTAssertEqual(EnergyFormat.duration(2 * 3_600 + 5 * 60), "2 h 5 min")
        XCTAssertEqual(EnergyFormat.duration(27 * 3_600 + 20 * 60), "27 h")
        XCTAssertEqual(EnergyFormat.bytes(900 * 1_024), "900 KB")
        XCTAssertEqual(EnergyFormat.bytes(12 * 1_048_576), "12 MB")
        XCTAssertEqual(EnergyFormat.watts(18.4), "18 W")
        XCTAssertTrue(EnergyFormat.watts(1.44).hasSuffix(" W"))
        XCTAssertTrue(EnergyFormat.watts(0.02).hasPrefix("<"))
        XCTAssertEqual(EnergyFormat.rate(246.4), "246/s")
    }

    func testSearchUnderstandsEnergyWakeupsAndWrites() {
        let query = ProcessSearchQuery("watts>2 wakeups>=150 writes>5mb disk:1gb/s")
        XCTAssertEqual(query.metrics.map(\.metric), [.energy, .wakeups, .writes, .writes])
        XCTAssertEqual(query.metrics[0].value, 2)
        XCTAssertEqual(query.metrics[2].value, 5 * 1_048_576)
        XCTAssertEqual(query.metrics[3].value, 1_073_741_824)
        XCTAssertEqual(ProcessSearchQuery("power>1.5w").metrics.first?.value, 1.5)

        let hungry = SearchMeasurements(cpuPercent: 3, memoryBytes: 0, gpuPercent: 0, threads: 4,
                                        energyWatts: 3.2, idleWakeupsPerSecond: 20, diskWriteBytesPerSecond: 0)
        let unmeasured = SearchMeasurements(cpuPercent: 3, memoryBytes: 0, gpuPercent: 0, threads: 4)
        let filter = ProcessSearchQuery("watts>2").metrics[0]
        XCTAssertTrue(filter.accepts(hungry.value(for: .energy)))
        XCTAssertFalse(filter.accepts(unmeasured.value(for: .energy)), "no reading never passes a filter")
    }
}
