import XCTest
@testable import GhostProcessSniperCore

final class EnergyFindingRulesTests: XCTestCase {
    private let now = EnergyFixture.start

    private func consumer(
        _ name: String = "Claude", kind: ThermalWorkloadKind = .app, watts: Double = 0.2, wakeups: Double = 0,
        cores: Double = 0.02, writes: Double = 0, observed: TimeInterval = 300, gained: Double? = nil,
        familyKey: String? = "family:claude", isSystem: Bool = false
    ) -> EnergyConsumer {
        EnergyConsumer(
            id: "group:\(name)", displayName: name, kind: kind, applicationPath: nil, hostAppName: nil,
            familyKey: familyKey, isSystem: isSystem, processCount: 3, wattsNow: watts, averageWatts: watts,
            lastHourWattHours: watts, wakeupsPerSecond: wakeups, diskWriteBytesPerSecond: writes,
            lastHourDiskBytesWritten: writes * 3_600, shareOfMeasured: 0.5, batteryMinutesGained: gained,
            observedSeconds: observed, averageCores: cores, tenMinuteDiskWriteBytesPerSecond: writes,
            tenMinuteObservedSeconds: observed * 2, busiestWakeups: wakeups > 0 ? WakeupLeader(name: name, perSecond: wakeups) : nil)
    }

    private func blocker(
        _ name: String = "Safari", heldFor: TimeInterval = 45 * 60, effect: SleepAssertionEffect = .systemSleep,
        reason: String = "An audio stream is open", idle: Bool = true, system: Bool = false, intentional: Bool = false
    ) -> SleepBlocker {
        SleepBlocker(id: "\(name)|\(effect.rawValue)", displayName: name, viaProcessName: "coreaudiod", pid: 500,
                     consumerID: "group:\(name)", familyKey: nil, effect: effect, reason: reason, rawName: "",
                     heldSince: now.addingTimeInterval(-heldFor), isSystem: system, isIntentional: intentional,
                     isIdle: idle)
    }

    private func evaluate(_ rules: inout EnergyFindingRules, consumers: [EnergyConsumer] = [],
                          blockers: [SleepBlocker] = [], battery: BatteryOutlook? = nil,
                          kinds: [String: DevProcessKind] = [:], at date: Date? = nil) -> [EnergyFinding] {
        rules.evaluate(consumers: consumers, blockers: blockers, battery: battery, classifications: kinds,
                       now: date ?? now)
    }

    func testIdleWakeupsUseTheKernelsOwnLimit() {
        var rules = EnergyFindingRules()
        XCTAssertTrue(evaluate(&rules, consumers: [consumer(wakeups: 140)]).isEmpty)
        let findings = evaluate(&rules, consumers: [consumer(wakeups: 246)])
        XCTAssertEqual(findings.map(\.kind), [.wakeups])
        XCTAssertEqual(findings.first?.headline, "Claude wakes the processor 246 times a second")
        XCTAssertEqual(findings.first?.severity, .notable)
        XCTAssertEqual(evaluate(&rules, consumers: [consumer(wakeups: 600)]).first?.severity, .attention)
    }

    func testAShowingFindingHoldsUntilItFallsWellBelowTheLimit() {
        var rules = EnergyFindingRules()
        let first = evaluate(&rules, consumers: [consumer(wakeups: 200)])
        let held = evaluate(&rules, consumers: [consumer(wakeups: 130)], at: now.addingTimeInterval(10))
        XCTAssertEqual(held.map(\.id), first.map(\.id), "130/s stays above 80% of the limit")
        XCTAssertEqual(held.first?.since, now, "the finding keeps its start")
        XCTAssertTrue(evaluate(&rules, consumers: [consumer(wakeups: 100)]).isEmpty)
    }

    func testWakeupsFromRealWorkOrTooLittleObservationAreNotFindings() {
        var rules = EnergyFindingRules()
        XCTAssertTrue(evaluate(&rules, consumers: [consumer(wakeups: 400, cores: 1.2)]).isEmpty, "busy, not idle")
        XCTAssertTrue(evaluate(&rules, consumers: [consumer(wakeups: 400, observed: 90)]).isEmpty, "not yet measured")
        XCTAssertTrue(evaluate(&rules, consumers: [consumer(wakeups: 400, isSystem: true)]).isEmpty, "macOS's own")
    }

    func testAnIdleAppHoldingTheMacAwakeForHalfAnHour() {
        var rules = EnergyFindingRules()
        let findings = evaluate(&rules, blockers: [blocker()])
        XCTAssertEqual(findings.first?.kind, .keepsMacAwake)
        XCTAssertEqual(findings.first?.headline, "Safari has kept your Mac awake for 45 min")
        XCTAssertTrue(findings.first?.advice.hasPrefix("Close the tab or window that played sound") ?? false)
        XCTAssertEqual(findings.first?.severity, .notable)
        XCTAssertEqual(evaluate(&rules, blockers: [blocker(heldFor: 3 * 3_600)]).first?.severity, .attention)
        let display = evaluate(&rules, blockers: [blocker(effect: .displaySleep, reason: "Asked macOS to keep the display on")])
        XCTAssertEqual(display.first?.headline, "Safari has kept your display on for 45 min")
    }

    func testBlockersThatAreBusyBriefIntentionalOrMacOSAreNotFindings() {
        var rules = EnergyFindingRules()
        XCTAssertTrue(evaluate(&rules, blockers: [blocker(idle: false)]).isEmpty, "a video call is work in progress")
        XCTAssertTrue(evaluate(&rules, blockers: [blocker(heldFor: 10 * 60)]).isEmpty)
        XCTAssertTrue(evaluate(&rules, blockers: [blocker("Amphetamine", intentional: true)]).isEmpty)
        XCTAssertTrue(evaluate(&rules, blockers: [blocker("powerd", system: true)]).isEmpty)
    }

    func testHeavyWritesAreFlaggedUnlessTheWorkloadWritesForALiving() {
        var rules = EnergyFindingRules()
        let logger = consumer("logspam", kind: .job, writes: 3_000_000, familyKey: "family:log")
        let findings = evaluate(&rules, consumers: [logger])
        XCTAssertEqual(findings.map(\.kind), [.heavyDiskWrites])
        XCTAssertTrue(findings.first?.advice.hasPrefix("If this is a log or cache") ?? false)

        var build = EnergyFindingRules()
        let compiler = consumer("swift-build", kind: .job, writes: 3_000_000, familyKey: "family:build")
        XCTAssertTrue(evaluate(&build, consumers: [compiler], kinds: ["family:build": .swiftBuild]).isEmpty)
        let flood = consumer("swift-build", kind: .job, writes: 30_000_000, familyKey: "family:build")
        XCTAssertEqual(evaluate(&build, consumers: [flood], kinds: ["family:build": .swiftBuild]).first?.severity,
                       .attention)
    }

    func testBatteryDrainNeedsBatteryPowerAndAMeaningfulShare() {
        let battery = BatteryOutlook(chargePercent: 70, isDischarging: true, isCharging: false, drawWatts: 12,
                                     remainingWattHours: 50, minutesRemaining: 250, healthPercent: 90,
                                     cycleCount: 100, adapterInputWatts: nil)
        var rules = EnergyFindingRules()
        let heavy = consumer("Chrome", watts: 4, gained: 125)
        XCTAssertEqual(evaluate(&rules, consumers: [heavy], battery: battery).map(\.kind), [.batteryDrain])
        XCTAssertTrue(evaluate(&rules, consumers: [consumer("Notes", watts: 1, gained: 25)], battery: battery).isEmpty,
                      "under a fifth of the draw")
        let plugged = BatteryOutlook(chargePercent: 70, isDischarging: false, isCharging: true, drawWatts: 12,
                                     remainingWattHours: 50, minutesRemaining: nil, healthPercent: 90,
                                     cycleCount: 100, adapterInputWatts: 60)
        XCTAssertTrue(evaluate(&rules, consumers: [heavy], battery: plugged).isEmpty)
    }

    func testFindingsLeadWithTheMostUrgent() {
        var rules = EnergyFindingRules()
        let findings = evaluate(&rules, consumers: [consumer(wakeups: 200)], blockers: [blocker(heldFor: 5 * 3_600)])
        XCTAssertEqual(findings.map(\.kind), [.keepsMacAwake, .wakeups])
    }
}

final class EnergyAlertGateTests: XCTestCase {
    private func finding(_ id: String, _ severity: EnergyFindingSeverity) -> EnergyFinding {
        EnergyFinding(id: id, kind: .keepsMacAwake, severity: severity, consumerID: id, displayName: id, familyKey: nil,
                      headline: id, detail: "", advice: "", since: .distantPast)
    }

    func testOnlyAttentionAlertsAndOnlyOnceWhileItLasts() {
        var gate = EnergyAlertGate()
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(gate.alerts(for: [finding("a", .attention), finding("b", .notable)], now: now).map(\.id), ["a"])
        XCTAssertTrue(gate.alerts(for: [finding("a", .attention)], now: now.addingTimeInterval(60)).isEmpty)
        // Gone, then back within the cooldown: still quiet; back the next night: alerts again.
        _ = gate.alerts(for: [], now: now.addingTimeInterval(120))
        XCTAssertTrue(gate.alerts(for: [finding("a", .attention)], now: now.addingTimeInterval(3_600)).isEmpty)
        _ = gate.alerts(for: [], now: now.addingTimeInterval(3_700))
        XCTAssertEqual(gate.alerts(for: [finding("a", .attention)], now: now.addingTimeInterval(13 * 3_600)).map(\.id), ["a"])
    }
}
