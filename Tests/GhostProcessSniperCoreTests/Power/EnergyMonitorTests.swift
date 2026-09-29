import XCTest
@testable import GhostProcessSniperCore

final class EnergyMonitorTests: XCTestCase {
    private let slack = "/Applications/Slack.app/Contents/MacOS/Slack"
    private let helper = "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"

    func testEnergyIsExactFromLifetimeCountersAndTheFirstSightingChargesNothing() {
        var driver = EnergyDriver()
        // Already 1,000 J into its life when first seen, then 2 J every 5 s tick.
        let report = driver.run(ticks: 13) { index, date in
            [EnergyFixture.process(pid: 10, name: "vite", path: "/usr/local/bin/node",
                                   counters: .init(joules: 1_000 + 2 * Double(index)), at: date)]
        }
        let vite = try? XCTUnwrap(report.consumers.first { $0.displayName == "vite" })
        XCTAssertEqual(vite?.averageWatts ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(vite?.lastHourWattHours ?? 0, 24.0 / 3_600, accuracy: 1e-9)
        XCTAssertEqual(report.lastHourWattHours, 24.0 / 3_600, accuracy: 1e-9)
        XCTAssertTrue(report.perProcessEnergy)
    }

    func testAnAppAndItsHelpersAreOneConsumer() {
        var driver = EnergyDriver()
        let report = driver.run(ticks: 7) { index, date in
            let step = Double(index)
            return [
                EnergyFixture.process(pid: 20, name: "Slack", path: slack, counters: .init(joules: step), at: date),
                EnergyFixture.process(pid: 21, name: "Slack Helper", path: helper, parent: 20,
                                      counters: .init(joules: 2 * step), at: date),
                EnergyFixture.process(pid: 22, name: "Slack Helper (Renderer)", path: helper, parent: 20,
                                      counters: .init(joules: 3 * step), at: date)
            ]
        }
        XCTAssertEqual(report.consumers.count, 1)
        let consumer = report.consumers[0]
        XCTAssertEqual(consumer.displayName, "Slack")
        XCTAssertEqual(consumer.kind, .app)
        XCTAssertEqual(consumer.processCount, 3)
        XCTAssertEqual(consumer.averageWatts, 6.0 / 5, accuracy: 0.001)
        XCTAssertEqual(consumer.shareOfMeasured, 1, accuracy: 0.001)
    }

    func testSleepIsNeitherObservedNorAveragedAway() {
        var driver = EnergyDriver()
        driver.run(ticks: 3) { index, date in
            [EnergyFixture.process(pid: 30, name: "job", path: "/usr/local/bin/job",
                                   counters: .init(joules: Double(index)), at: date)]
        }
        // Two hours asleep: the counter barely moved, and the gap is not observed time.
        driver.now = driver.now.addingTimeInterval(7_200)
        let report = driver.run(ticks: 1) { _, date in
            [EnergyFixture.process(pid: 30, name: "job", path: "/usr/local/bin/job",
                                   counters: .init(joules: 5), at: date)]
        }
        let window = driver.monitor.ledger.window(report.consumers[0].id, minutes: 5)
        XCTAssertLessThanOrEqual(window.observedSeconds, EnergyLedger.maximumGap)
        XCTAssertEqual(window.joules, 3, accuracy: 1e-9, "the energy used across the gap is still charged")
    }

    func testMacsWithoutPerProcessEnergyRankByWakeupsAndWrites() {
        var driver = EnergyDriver()
        let report = driver.run(ticks: 5) { index, date in
            [
                EnergyFixture.process(pid: 40, name: "quiet", path: "/usr/local/bin/quiet",
                                      counters: .init(wakeups: UInt64(index) * 10), at: date),
                EnergyFixture.process(pid: 41, name: "busy", path: "/usr/local/bin/busy",
                                      counters: .init(wakeups: UInt64(index) * 2_000), at: date)
            ]
        }
        XCTAssertFalse(report.perProcessEnergy)
        XCTAssertEqual(report.consumers.map(\.displayName), ["busy", "quiet"])
        XCTAssertEqual(report.consumers[0].wakeupsPerSecond, 400, accuracy: 0.001)
    }

    func testAnXPCServiceIsAttributedToTheAppResponsibleForIt() {
        let now = EnergyFixture.start
        let safari = EnergyFixture.process(pid: 500, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari",
                                           counters: .init(), at: now)
        let tab = EnergyFixture.process(
            pid: 510, name: "com.apple.WebKit.WebContent",
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            counters: .init(), at: now)
        var plain = ThermalWorkloadResolver(processes: [safari, tab])
        XCTAssertEqual(plain.assignment(for: tab).kind, .process)
        var hinted = ThermalWorkloadResolver(processes: [safari, tab], responsiblePIDs: [tab.identity: 500])
        XCTAssertEqual(hinted.assignment(for: tab).groupKey, "/Applications/Safari.app")
        XCTAssertEqual(hinted.assignment(for: tab).kind, .app)

        var lookup = ResponsibleProcessLookup(query: { $0 == 510 ? 500 : nil })
        XCTAssertEqual(lookup.hints(for: [safari, tab], now: now), [tab.identity: 500])
    }

    func testWakeupsAreJudgedPerProcessLikeMacOSDoes() {
        var driver = EnergyDriver()
        let spread = driver.run(ticks: 70) { index, date in
            let counters = EnergyFixture.Counters(wakeups: UInt64(index) * 500)
            return [
                EnergyFixture.process(pid: 80, name: "Slack", path: slack, counters: counters, at: date),
                EnergyFixture.process(pid: 81, name: "Slack Helper", path: helper, parent: 80, counters: counters, at: date),
                EnergyFixture.process(pid: 82, name: "Slack Helper", path: helper, parent: 80, counters: counters, at: date)
            ]
        }
        XCTAssertEqual(spread.consumers[0].wakeupsPerSecond, 300, accuracy: 0.01)
        XCTAssertEqual(spread.consumers[0].busiestWakeups?.perSecond ?? 0, 100, accuracy: 0.01)
        XCTAssertTrue(spread.findings.isEmpty, "three helpers at 100 a second each stay under macOS's per-process limit")

        var single = EnergyDriver()
        let busy = single.run(ticks: 70) { index, date in
            [
                EnergyFixture.process(pid: 90, name: "Slack", path: slack, counters: .init(), at: date),
                EnergyFixture.process(pid: 91, name: "Slack Helper (Renderer)", path: helper, parent: 90,
                                      counters: .init(wakeups: UInt64(index) * 1_000), at: date)
            ]
        }
        let finding = busy.findings.first
        XCTAssertEqual(finding?.kind, .wakeups)
        XCTAssertEqual(finding?.headline, "Slack wakes the processor 200 times a second")
        XCTAssertTrue(finding?.detail.hasPrefix("Slack Helper (Renderer), one of its processes") ?? false)
    }

    // MARK: - Sleep blockers

    func testAudioHeldByCoreaudiodIsBlamedOnTheAppPlayingIt() {
        let started = EnergyFixture.start.addingTimeInterval(-3 * 3_600)
        let assertions = ScriptedAssertions([
            SleepAssertion(pid: 88, processName: "coreaudiod", type: "PreventUserIdleSystemSleep", effect: .systemSleep,
                           name: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep",
                           startedAt: started, onBehalfOfPID: 500),
            SleepAssertion(pid: 90, processName: "powerd", type: "PreventUserIdleSystemSleep", effect: .systemSleep,
                           name: "Powerd - Prevent sleep while display is on", startedAt: started)
        ])
        var driver = EnergyDriver(assertions: assertions)
        let report = driver.run(ticks: 2) { _, date in
            [
                EnergyFixture.process(pid: 500, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari",
                                      counters: .init(), at: date),
                EnergyFixture.process(pid: 88, name: "coreaudiod", path: "/usr/sbin/coreaudiod", counters: .init(), at: date),
                EnergyFixture.process(pid: 90, name: "powerd", path: "/usr/libexec/powerd", counters: .init(), at: date)
            ]
        }
        let safari = try? XCTUnwrap(report.blockers.first { $0.displayName == "Safari" })
        XCTAssertEqual(safari?.viaProcessName, "coreaudiod")
        XCTAssertEqual(safari?.reason, "An audio stream is open")
        XCTAssertEqual(safari?.isSystem, false)
        XCTAssertEqual(report.blockers.first { $0.displayName == "powerd" }?.isSystem, true)
        XCTAssertEqual(report.unexpectedBlockers.map(\.displayName), ["Safari"])
    }

    func testKeepAwakeUtilitiesAndBoundedCaffeinateAreIntentional() {
        func process(_ name: String, _ command: String) -> ProcessMetrics {
            EnergyFixture.process(pid: 7, name: name, path: "/usr/bin/\(name)", command: command, counters: .init(),
                                  at: EnergyFixture.start)
        }
        XCTAssertTrue(EnergyReportBuilder.isIntentional(name: "Amphetamine", process: nil))
        XCTAssertTrue(EnergyReportBuilder.isIntentional(name: "caffeinate", process: process("caffeinate", "caffeinate -t 3600")))
        XCTAssertTrue(EnergyReportBuilder.isIntentional(name: "caffeinate", process: process("caffeinate", "caffeinate -i make")))
        XCTAssertFalse(EnergyReportBuilder.isIntentional(name: "caffeinate", process: process("caffeinate", "caffeinate -dims")))
        XCTAssertFalse(EnergyReportBuilder.isIntentional(name: "Slack", process: nil))
    }

    func testAForgottenCaffeinateBecomesAFindingOnceIdleForTenMinutes() {
        let assertions = ScriptedAssertions([
            SleepAssertion(pid: 60, processName: "caffeinate", type: "PreventUserIdleSystemSleep", effect: .systemSleep,
                           name: "caffeinate command-line tool", startedAt: EnergyFixture.start.addingTimeInterval(-7_200))
        ])
        var driver = EnergyDriver(assertions: assertions, tick: 10)
        let make: (Int, Date) -> [ProcessMetrics] = { _, date in
            [EnergyFixture.process(pid: 60, name: "caffeinate", path: "/usr/bin/caffeinate", command: "caffeinate -dims",
                                   counters: .init(joules: 1, cpuSeconds: 0.2), at: date)]
        }
        let early = driver.run(ticks: 20, families: { [EnergyFixture.family($0)] }, processes: make)
        XCTAssertTrue(early.findings.isEmpty, "idleness needs five minutes of observation first")
        let later = driver.run(ticks: 20, families: { [EnergyFixture.family($0)] }, processes: make)
        let finding = try? XCTUnwrap(later.findings.first)
        XCTAssertEqual(finding?.kind, .keepsMacAwake)
        XCTAssertEqual(finding?.severity, .attention, "held for more than two hours")
        XCTAssertNotNil(finding?.familyKey)
        XCTAssertTrue(finding?.headline.hasPrefix("caffeinate has kept your Mac awake for") ?? false)
        XCTAssertEqual(later.families[finding?.familyKey ?? ""]?.keepsAwake, .systemSleep)
    }

    // MARK: - Battery

    func testBatteryTimeGainedIfAConsumerStopped() {
        let battery = ScriptedBattery.discharging(watts: 10)
        var driver = EnergyDriver(battery: battery)
        let report = driver.run(ticks: 61) { index, date in
            [EnergyFixture.process(pid: 70, name: "render", path: "/usr/local/bin/render",
                                   counters: .init(joules: 20 * Double(index)), at: date)]
        }
        let outlook = try? XCTUnwrap(report.battery)
        XCTAssertEqual(outlook?.remainingWattHours ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(outlook?.minutesRemaining ?? 0, 360, accuracy: 0.5)
        let render = report.consumers[0]
        XCTAssertEqual(render.averageWatts, 4, accuracy: 0.01)
        // 60 Wh at 6 W instead of 10 W: 10 h instead of 6 h.
        XCTAssertEqual(render.batteryMinutesGained ?? 0, 240, accuracy: 1)
        let drain = report.findings.first { $0.kind == .batteryDrain }
        XCTAssertEqual(drain?.severity, .attention)
        XCTAssertEqual(drain?.headline, "render is costing about 4 h of battery")

        battery.set { $0.onExternalPower = true }
        let plugged = driver.run(ticks: 1) { index, date in
            [EnergyFixture.process(pid: 70, name: "render", path: "/usr/local/bin/render",
                                   counters: .init(joules: 20 * Double(61 + index)), at: date)]
        }
        XCTAssertNil(plugged.consumers[0].batteryMinutesGained)
        XCTAssertFalse(plugged.findings.contains { $0.kind == .batteryDrain })
    }

    func testTheBatteryIsReadOnItsOwnSlowerCadenceWhileHidden() {
        let battery = ScriptedBattery.discharging(watts: 8)
        var driver = EnergyDriver(battery: battery, tick: 3)
        driver.run(ticks: 10, visible: false) { _, date in
            [EnergyFixture.process(pid: 1, name: "x", path: "/x", counters: .init(), at: date)]
        }
        // 27 s of hidden scans at a 15 s battery interval: reads at 0 s and 15 s.
        XCTAssertEqual(battery.reads, 2)
    }

    func testTheGlanceOnlyChangesWhenARoundedFigureDoes() {
        let battery = ScriptedBattery.discharging(watts: 10)
        var driver = EnergyDriver(battery: battery, tick: 2)
        let make: (Int, Date) -> [ProcessMetrics] = { index, date in
            [EnergyFixture.process(pid: 1, name: "x", path: "/x", counters: .init(joules: 2 * Double(index)), at: date)]
        }
        let first = EnergyGlance(driver.run(ticks: 3, processes: make))
        battery.set { $0.batteryDischargeWatts = 10.2 }
        let second = EnergyGlance(driver.run(ticks: 2, processes: make))
        XCTAssertEqual(first, second)
        XCTAssertEqual(second.batteryLine?.hasPrefix("On battery 80%"), true)
    }

    // MARK: - The header's power state

    private func idle(_ index: Int, _ date: Date) -> [ProcessMetrics] {
        [EnergyFixture.process(pid: 1, name: "x", path: "/x", counters: .init(joules: 2 * Double(index)), at: date)]
    }

    func testTheChargerIsLabelledByItsRatingAndTheStateFollowsTheFlow() {
        let battery = ScriptedBattery.pluggedIn(amperage: 2_540, load: 31, input: 39, rated: 65)
        var driver = EnergyDriver(battery: battery, tick: 2)
        let charging = driver.run(ticks: 3, processes: idle)
        XCTAssertEqual(charging.battery?.adapterRatedWatts, 65)
        XCTAssertEqual(charging.battery?.powerState, .charging)
        XCTAssertEqual(EnergyHeadline(charging).chargerTag, "Charger \(EnergyFormat.watts(65))")
        XCTAssertEqual(EnergyHeadline(charging).title, "Charging \u{00B7} 76%")

        // The Mac now wants 94 W of a 65 W charger: the flag still says charging, the current says otherwise.
        battery.set { $0.amperageMilliamps = -2_300; $0.systemLoadWatts = 94; $0.adapterInputWatts = 65 }
        let short = driver.run(ticks: 2, processes: idle)
        XCTAssertEqual(short.battery?.powerState, .drainingOnPower)
        XCTAssertEqual(EnergyHeadline(short).title, "Draining while plugged in \u{00B7} 76%")
        XCTAssertEqual(EnergyHeadline(short).chargerTag, "Charger \(EnergyFormat.watts(65))", "the chip does not move with load")

        battery.set { $0.onExternalPower = false; $0.isCharging = false }
        let unplugged = driver.run(ticks: 2, processes: idle)
        XCTAssertEqual(unplugged.battery?.powerState, .onBattery)
        XCTAssertNil(unplugged.battery?.adapterRatedWatts, "no charger, no rating")
    }

    func testTheStateHoldsAcrossScansThatDriftAcrossTheDeadBand() {
        let battery = ScriptedBattery.pluggedIn(amperage: -2_300, load: 94, input: 65, rated: 65)
        var driver = EnergyDriver(battery: battery, tick: 2)
        XCTAssertEqual(driver.run(ticks: 2, processes: idle).battery?.powerState, .drainingOnPower)
        battery.set { $0.amperageMilliamps = -64 }     // -0.8 W: still a drain, only a smaller one
        XCTAssertEqual(driver.run(ticks: 2, processes: idle).battery?.powerState, .drainingOnPower)
        battery.set { $0.amperageMilliamps = 0 }
        XCTAssertEqual(driver.run(ticks: 2, processes: idle).battery?.powerState, .pluggedIn)
        battery.set { $0.amperageMilliamps = -64 }     // and from here it is too small to start one
        XCTAssertEqual(driver.run(ticks: 2, processes: idle).battery?.powerState, .pluggedIn)
    }
}
