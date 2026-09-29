import XCTest
@testable import GhostProcessSniperCore

final class EnergyFindingRulesTests: XCTestCase {
    private let now = EnergyFixture.start

    private func consumer(
        _ name: String = "Claude", kind: ThermalWorkloadKind = .app, watts: Double = 0.2, wakeups: Double = 0,
        busiest: Double? = nil, leader: String? = nil, cores: Double = 0.02, writes: Double = 0,
        observed: TimeInterval = 300, gained: Double? = nil, familyKey: String? = "family:claude",
        isSystem: Bool = false, devKind: DevProcessKind? = nil, processCount: Int = 3
    ) -> EnergyConsumer {
        // `wakeups` is the group's sum; unless said otherwise one process makes all of it.
        let top = busiest ?? wakeups
        return EnergyConsumer(
            id: "group:\(name)", displayName: name, kind: kind, applicationPath: nil, hostAppName: nil,
            familyKey: familyKey, devKind: devKind, isSystem: isSystem, processCount: processCount, wattsNow: watts,
            averageWatts: watts, lastHourWattHours: watts, wakeupsPerSecond: wakeups, diskWriteBytesPerSecond: writes,
            lastHourDiskBytesWritten: writes * 3_600, shareOfMeasured: 0.5, batteryMinutesGained: gained,
            observedSeconds: observed, averageCores: cores, tenMinuteDiskWriteBytesPerSecond: writes,
            tenMinuteObservedSeconds: observed * 2,
            busiestWakeups: top > 0 ? WakeupLeader(name: leader ?? name, perSecond: top) : nil)
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
                          at date: Date? = nil) -> [EnergyFinding] {
        rules.evaluate(consumers: consumers, blockers: blockers, battery: battery, now: date ?? now)
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

    // MARK: - One finding per holder

    private func display(_ name: String, heldFor: TimeInterval) -> SleepBlocker {
        blocker(name, heldFor: heldFor, effect: .displaySleep, reason: "Asked macOS to keep the display on")
    }

    func testAnAppKeepingBothTheMacAndItsDisplayAwakeIsOneFinding() {
        var rules = EnergyFindingRules()
        let both = [blocker("Zoom", heldFor: 3 * 3_600), display("Zoom", heldFor: 45 * 60)]
        let findings = evaluate(&rules, blockers: both)
        XCTAssertEqual(findings.map(\.kind), [.keepsMacAwake], "one app, one card, one notification")
        XCTAssertEqual(findings.first?.headline, "Zoom has kept your Mac awake for 3 h", "the longest-held assertion leads")
        XCTAssertEqual(findings.first?.severity, .attention)
        XCTAssertTrue(findings.first?.detail.hasSuffix(" Zoom also keeps the display on.") ?? false)

        var other = EnergyFindingRules()
        let flipped = evaluate(&other, blockers: [blocker("Zoom", heldFor: 45 * 60), display("Zoom", heldFor: 3 * 3_600)])
        XCTAssertEqual(flipped.first?.headline, "Zoom has kept your display on for 3 h")
        XCTAssertTrue(flipped.first?.detail.hasSuffix(" Zoom also keeps the Mac awake.") ?? false)

        var apart = EnergyFindingRules()
        XCTAssertEqual(evaluate(&apart, blockers: both + [blocker("Teams", heldFor: 3_600)]).count, 2,
                       "another app is another finding")
    }

    func testTheOtherAssertionIsOnlyMentionedWhenItHasHeldLongEnoughToo() {
        var rules = EnergyFindingRules()
        let findings = evaluate(&rules, blockers: [blocker("Zoom", heldFor: 3 * 3_600), display("Zoom", heldFor: 10 * 60)])
        XCTAssertEqual(findings.count, 1)
        XCTAssertFalse(findings.first?.detail.contains("also") ?? true, "10 minutes is not yet worth a finding")

        var tied = EnergyFindingRules()
        let same = evaluate(&tied, blockers: [display("Zoom", heldFor: 3_600), blocker("Zoom", heldFor: 3_600)])
        XCTAssertEqual(same.first?.headline, "Zoom has kept your Mac awake for 1 h", "a tie goes to the whole Mac")
        XCTAssertTrue(same.first?.detail.hasSuffix(" Zoom also keeps the display on.") ?? false)
    }

    func testAHolderNoGroupOwnsIsStillOneFindingPerProcess() {
        func loose(_ pid: Int32, _ effect: SleepAssertionEffect) -> SleepBlocker {
            SleepBlocker(id: "pid:\(pid)|\(effect.rawValue)", displayName: "worker", viaProcessName: nil, pid: pid,
                         consumerID: nil, familyKey: nil, effect: effect, reason: "caffeinate is running", rawName: "",
                         heldSince: now.addingTimeInterval(-3_600), isSystem: false, isIntentional: false, isIdle: true)
        }
        var rules = EnergyFindingRules()
        let findings = evaluate(&rules, blockers: [loose(700, .systemSleep), loose(700, .displaySleep), loose(701, .systemSleep)])
        XCTAssertEqual(findings.map(\.consumerID).sorted(), ["pid:700", "pid:701"])
    }

    func testTheFindingKeepsItsIdAndStartWhileEitherAssertionHoldsOn() {
        var rules = EnergyFindingRules()
        let first = evaluate(&rules, blockers: [blocker("Zoom", heldFor: 3_600), display("Zoom", heldFor: 3_600)])
        // The display assertion is let go, and the Mac assertion is now the only one.
        let later = evaluate(&rules, blockers: [blocker("Zoom", heldFor: 3_600 + 60)], at: now.addingTimeInterval(60))
        XCTAssertEqual(later.map(\.id), first.map(\.id))
        XCTAssertEqual(later.first?.since, now)
        XCTAssertFalse(later.first?.detail.contains("also") ?? true)
        // Held only by the display, at 80% of the half hour, a showing finding holds on.
        let easing = evaluate(&rules, blockers: [display("Zoom", heldFor: 25 * 60)], at: now.addingTimeInterval(120))
        XCTAssertEqual(easing.map(\.id), first.map(\.id))
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
        let compiler = consumer("swift-build", kind: .job, writes: 3_000_000, familyKey: "family:build",
                                devKind: .swiftBuild)
        XCTAssertTrue(evaluate(&build, consumers: [compiler]).isEmpty)
        let flood = consumer("swift-build", kind: .job, writes: 30_000_000, familyKey: "family:build",
                             devKind: .swiftBuild)
        XCTAssertEqual(evaluate(&build, consumers: [flood]).first?.severity, .attention)
    }

    // MARK: - The Energy rows judge like the findings

    func testAWakeupFigureIsFlaggedWhenTheBusiestProcessIsOverMacOSsLimit() {
        // Three helpers at 100 a second each add up to 300, but none is near the limit of 150.
        XCTAssertFalse(consumer(wakeups: 300, busiest: 100).wakesProcessorTooOften)
        XCTAssertTrue(consumer(wakeups: 200).wakesProcessorTooOften, "one process at 200 in an idle app")
        XCTAssertTrue(consumer(wakeups: 350, busiest: 200).wakesProcessorTooOften, "the busiest one is what counts")
        XCTAssertFalse(consumer(wakeups: 149).wakesProcessorTooOften)
        XCTAssertFalse(consumer(wakeups: 200, cores: 1.2).wakesProcessorTooOften, "busy, not idle")
        XCTAssertFalse(consumer(wakeups: 200, observed: 90).wakesProcessorTooOften, "not yet measured")
        XCTAssertFalse(consumer(wakeups: 200, isSystem: true).wakesProcessorTooOften, "macOS's own")
        XCTAssertFalse(consumer(wakeups: 200, processCount: 0).wakesProcessorTooOften, "already exited")
        XCTAssertFalse(consumer(wakeups: 0).wakesProcessorTooOften, "no process averaged long enough yet")
    }

    func testTheWakeupFlagAndTheFindingNeverDisagree() {
        let cases: [(wakeups: Double, busiest: Double?, cores: Double)] = [
            (300, 100, 0.02), (200, nil, 0.02), (200, nil, 0.25), (200, nil, 1.2), (149, nil, 0.02), (150, nil, 0.02),
            (600, 300, 0.1), (500, 120, 0.02)
        ]
        for value in cases {
            let subject = consumer(wakeups: value.wakeups, busiest: value.busiest, cores: value.cores)
            var rules = EnergyFindingRules()
            let flagged = evaluate(&rules, consumers: [subject]).contains { $0.kind == .wakeups }
            XCTAssertEqual(subject.wakesProcessorTooOften, flagged, "\(value)")
        }
    }

    func testAShowingFindingKeepsItsHoldButTheFigureIsOnlyColouredAboveTheLimit() {
        var rules = EnergyFindingRules()
        XCTAssertEqual(evaluate(&rules, consumers: [consumer(wakeups: 200)]).count, 1)
        let easing = consumer(wakeups: 130)
        XCTAssertEqual(evaluate(&rules, consumers: [easing], at: now.addingTimeInterval(10)).count, 1,
                       "the finding holds until 80% of the limit")
        XCTAssertFalse(easing.wakesProcessorTooOften, "a row never says more than the limit itself")
    }

    func testTheWakeupsTooltipNamesTheBusiestProcessAndSaysWhatOrangeMeans() {
        let limit = "Orange means one process passes macOS\u{2019}s limit of 150 wake-ups a second while Claude uses under a quarter of a core."
        XCTAssertEqual(consumer(wakeups: 300, busiest: 100, leader: "Claude Helper (Renderer)").wakeupsNote,
                       "Busiest process: Claude Helper (Renderer), 100/s. " + limit)
        XCTAssertEqual(consumer(wakeups: 90, processCount: 1).wakeupsNote, limit, "alone, the sum is the busiest")
        XCTAssertNil(consumer(wakeups: 0).wakeupsNote, "nothing averaged long enough yet")
    }

    func testAWriteFigureIsFlaggedLikeTheHeavyWritesFinding() {
        XCTAssertTrue(consumer("logspam", kind: .job, writes: 3_000_000).writesTooMuch)
        XCTAssertFalse(consumer("logspam", kind: .job, writes: 1_500_000).writesTooMuch, "under 1 GB in ten minutes")
        // Builds, tests and databases write for a living: they are flagged at 20 MB/s, not 1.7.
        let compiler = consumer("swift-build", kind: .job, writes: 3_000_000, devKind: .swiftBuild)
        XCTAssertFalse(compiler.writesTooMuch)
        XCTAssertTrue(consumer("swift-build", kind: .job, writes: 30_000_000, devKind: .swiftBuild).writesTooMuch)
        XCTAssertFalse(consumer("logspam", kind: .job, writes: 3_000_000, observed: 200).writesTooMuch,
                       "under eight minutes observed")
        XCTAssertFalse(consumer("Spotlight", kind: .knownSource(.spotlight), writes: 3_000_000).writesTooMuch)
        XCTAssertFalse(consumer("cloudd", writes: 3_000_000, isSystem: true).writesTooMuch, "macOS's own")
        XCTAssertFalse(consumer("logspam", writes: 3_000_000, processCount: 0).writesTooMuch, "already exited")
    }

    func testTheWriteFlagAndTheFindingNeverDisagree() {
        let cases: [(writes: Double, kind: DevProcessKind?, system: Bool)] = [
            (3_000_000, nil, false), (1_500_000, nil, false), (3_000_000, .swiftBuild, false),
            (30_000_000, .swiftBuild, false), (3_000_000, .dataStore, false), (3_000_000, .nodeServer, false),
            (3_000_000, nil, true)
        ]
        for value in cases {
            let subject = consumer("job", kind: .job, writes: value.writes, isSystem: value.system, devKind: value.kind)
            var rules = EnergyFindingRules()
            let flagged = evaluate(&rules, consumers: [subject]).contains { $0.kind == .heavyDiskWrites }
            XCTAssertEqual(subject.writesTooMuch, flagged, "\(value)")
        }
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

    func testTheDrainIsJudgedAgainstTheFiveMinuteDrawItIsAveragedOver() {
        // The last minute spiked to 30 W, but over the five minutes the app was measured the Mac drew 12 W.
        let battery = BatteryOutlook(chargePercent: 70, isDischarging: true, isCharging: false, drawWatts: 30,
                                     remainingWattHours: 50, minutesRemaining: 100, healthPercent: 90,
                                     cycleCount: 100, adapterInputWatts: nil, averageDrawWatts: 12)
        var rules = EnergyFindingRules()
        let finding = evaluate(&rules, consumers: [consumer("Chrome", watts: 4, gained: 125)], battery: battery).first
        XCTAssertEqual(finding?.kind, .batteryDrain, "4 W is a third of 12 W, though not a fifth of 30 W")
        XCTAssertEqual(finding?.detail, "It used \(EnergyFormat.watts(4)) of the \(EnergyFormat.watts(12)) your Mac is drawing, averaged over 5 minutes.")
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

    func testACooldownSurvivesARelaunch() {
        var first = EnergyAlertGate()
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(first.alerts(for: [finding("Safari|keepsMacAwake", .attention)], now: now).count, 1)

        // Ghost restarts while Safari still holds the Mac awake.
        var second = EnergyAlertGate(memory: first.memory, now: now.addingTimeInterval(3_600))
        XCTAssertTrue(second.alerts(for: [finding("Safari|keepsMacAwake", .attention)], now: now.addingTimeInterval(3_600)).isEmpty)
        XCTAssertEqual(second.alerts(for: [finding("Notes|keepsMacAwake", .attention)], now: now.addingTimeInterval(3_600)).count, 1,
                       "another app is still news")

        var nextNight = EnergyAlertGate(memory: first.memory, now: now.addingTimeInterval(13 * 3_600))
        XCTAssertEqual(nextNight.alerts(for: [finding("Safari|keepsMacAwake", .attention)],
                                        now: now.addingTimeInterval(13 * 3_600)).count, 1)
    }

    func testTheSavedEnergyMemoryHoldsHashesNotAppNames() throws {
        var gate = EnergyAlertGate()
        _ = gate.alerts(for: [finding("com.apple.Safari|keepsMacAwake", .attention)], now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(gate.memory.lastAlerted.keys.first, AlertMemory.hash("com.apple.Safari|keepsMacAwake"))
        let saved = try XCTUnwrap(String(data: JSONEncoder().encode(gate.memory), encoding: .utf8))
        XCTAssertFalse(saved.contains("Safari"))
    }

    func testAnOldOrFutureMemoryIsDroppedOnRestore() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var first = EnergyAlertGate()
        _ = first.alerts(for: [finding("a", .attention)], now: now)
        XCTAssertTrue(EnergyAlertGate(memory: first.memory, now: now.addingTimeInterval(13 * 3_600)).memory.lastAlerted.isEmpty)
        XCTAssertTrue(EnergyAlertGate(memory: first.memory, now: now.addingTimeInterval(-60)).memory.lastAlerted.isEmpty)
    }
}
