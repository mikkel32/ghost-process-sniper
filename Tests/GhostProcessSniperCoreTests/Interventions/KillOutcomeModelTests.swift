import Darwin
import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The outcome model learns how a family stops from its own stops, with its
/// kind as the prior. One stop never moves it far, learning never waits
/// less than a clean shutdown needs, and only proven non-exits get a short
/// wait before force.
final class KillOutcomeModelTests: XCTestCase {
    func testTwentyCleanFastExitsKeepGraceAtFloor() {
        let outcomes = Self.history(Array(repeating: Self.clean(0.3), count: 20))
        let forecast = KillOutcomeModel(history: outcomes)
            .forecast(strategy: .standard, workloadKind: .general, floorSeconds: 2, forceKillDelay: 2)
        XCTAssertEqual(forecast.graceSeconds, 2, "a quick family still gets the full wait; it ends on exit")
        XCTAssertGreaterThan(forecast.pClean, 0.9)
        XCTAssertEqual(forecast.observationCount, 20)
        XCTAssertTrue(forecast.evidenceText.hasPrefix("Stopped cleanly 20 of 20 times, usually within 0."), forecast.evidenceText)
    }

    func testEvidenceCountsEveryCleanStopNotTheDecayedShare() {
        let outcomes = Self.history(Array(repeating: Self.clean(0.3), count: 9) + [Self.forced()])
        let forecast = KillOutcomeModel(history: outcomes)
            .forecast(strategy: .standard, workloadKind: .general, floorSeconds: 2, forceKillDelay: 2)
        XCTAssertLessThan(forecast.pClean, 0.9, "the latest stop weighs most")
        XCTAssertTrue(forecast.evidenceText.hasPrefix("Stopped cleanly 9 of 10 times"), forecast.evidenceText)
    }

    func testOneFastOutcomeNeverShortensGrace() {
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", outcomes: Self.history([Self.clean(0.3)]))
        XCTAssertEqual(evaluation.profile.graceSeconds, 2)
        XCTAssertEqual(evaluation.profile.phases.first?.waitAfterSeconds, 2)
    }

    func testOneForcedSampleDoesNotChangeStrategy() {
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", outcomes: Self.history([Self.forced()]))
        XCTAssertEqual(evaluation.recommendation.strategy, .standard)
        XCTAssertEqual(evaluation.profile.graceSeconds, 2)
    }

    func testTwoForcedSamplesDoNotFlipToStubborn() {
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher",
                                                outcomes: Self.history([Self.forced(), Self.forced()]))
        XCTAssertEqual(evaluation.recommendation.strategy, .standard)
    }

    func testForcedOutcomesDoNotGrowGrace() {
        let outcomes = Self.history([Self.forced(), Self.forced(), Self.forced()])
        let forecast = KillOutcomeModel(history: outcomes)
            .forecast(strategy: .standard, workloadKind: .general, floorSeconds: 2, forceKillDelay: 2)
        XCTAssertEqual(forecast.graceSeconds, 2, "waiting longer for a process that ignores SIGTERM only delays force")
    }

    func testFourFullWaitNonExitsBecomeStubbornWithShortGrace() {
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher",
                                                outcomes: Self.history(Array(repeating: Self.forced(), count: 4)))
        XCTAssertEqual(evaluation.recommendation.strategy, .stubbornRunaway)
        XCTAssertEqual(evaluation.profile.graceSeconds, 0.5)
        XCTAssertEqual(evaluation.profile.phases.first?.waitAfterSeconds, 0.5)
        XCTAssertTrue(evaluation.recommendation.reasons.first?.contains("0 of 4") == true, "\(evaluation.recommendation.reasons)")
    }

    func testUnclassifiedFamilyNeedsMoreThanFourNonExitsToBeStubborn() {
        // Without a kind row the family's stops are its evidence only, not
        // also its prior, so four ignored SIGTERMs are not yet proof.
        let fourStops = Self.history(Array(repeating: Self.forced(), count: 4), kindToo: false)
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", outcomes: fourStops)
        XCTAssertEqual(evaluation.recommendation.strategy, .standard)
        XCTAssertEqual(evaluation.profile.graceSeconds, 2)

        let manyStops = Self.history(Array(repeating: Self.forced(), count: 20), kindToo: false)
        XCTAssertEqual(PolicyFixture.evaluate(command: "cruncher", name: "cruncher", outcomes: manyStops).recommendation.strategy,
                       .stubbornRunaway, "a family that keeps ignoring SIGTERM gets there on its own record")
    }

    func testDataLossWorkloadsIgnoreStubbornEvidence() {
        let evaluation = PolicyFixture.evaluate(command: "npm install", name: "npm",
                                                outcomes: Self.history(Array(repeating: Self.forced(grace: 4), count: 8)))
        XCTAssertEqual(evaluation.recommendation.strategy, .standard)
        XCTAssertEqual(evaluation.profile.graceSeconds, 4)
    }

    func testStubbornCleanExitsBringAFamilyBack() {
        var observations = Array(repeating: Self.forced(), count: 4)
        observations += Array(repeating: Self.clean(0.3, strategy: .stubbornRunaway), count: 6)
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", outcomes: Self.history(observations))
        XCTAssertEqual(evaluation.recommendation.strategy, .standard)
        XCTAssertEqual(evaluation.profile.graceSeconds, 2)
    }

    func testQuickSigkillsDoNotKeepAFamilyStubborn() {
        let base = Self.history(Array(repeating: Self.forced(), count: 4))
        let more = Self.history(Array(repeating: Self.forced(), count: 4) + Array(repeating: Self.forced(grace: 0.5, strategy: .stubbornRunaway), count: 10))
        let before = KillOutcomeModel(history: base).forecast(strategy: .standard, workloadKind: .general, floorSeconds: 2, forceKillDelay: 2)
        let after = KillOutcomeModel(history: more).forecast(strategy: .standard, workloadKind: .general, floorSeconds: 2, forceKillDelay: 2)
        XCTAssertEqual(after.pClean, before.pClean, accuracy: 1e-9, "a SIGKILL after 0.5 s says nothing about SIGTERM")
    }

    func testCensoredObservationsRaiseQ90() {
        var posterior = KillOutcomePosterior.empty
        for _ in 0..<10 {
            posterior = posterior.updating(with: Self.clean(1.5), at: Date())
        }
        let uncensored = posterior.latencyQuantile(0.9) ?? 0
        for _ in 0..<3 {
            posterior = posterior.updating(with: Self.forced(grace: 2), at: Date())
        }
        let censored = posterior.latencyQuantile(0.9) ?? 0
        XCTAssertLessThanOrEqual(uncensored, 2)
        XCTAssertGreaterThan(censored, 2, "a wait that ran out means the exit comes after the grace")
        let forecast = KillOutcomeModel(history: KillOutcomeHistory(signature: [.standard: posterior]))
            .forecast(strategy: .standard, workloadKind: .general, floorSeconds: 2, forceKillDelay: 2)
        XCTAssertGreaterThan(forecast.graceSeconds, 2, "late exits earn a longer wait")
        XCTAssertLessThanOrEqual(forecast.graceSeconds, 6, "up to three times the force delay")
    }

    func testPosteriorConvergesWithin0_1After30Observations() {
        // Decayed counts remember about ten stops, so one family's estimate
        // stays a little noisy by design; across families it is unbiased
        // apart from a small pull toward the prior.
        var generator = SeededGenerator(seed: 42)
        var estimates: [Double] = []
        for _ in 0..<200 {
            let observations = (0..<30).map { _ in
                Double.random(in: 0..<1, using: &generator) < 0.7 ? Self.clean(0.4) : Self.forced()
            }
            let forecast = KillOutcomeModel(history: Self.history(observations, kindToo: false))
                .forecast(strategy: .standard, workloadKind: .general, floorSeconds: 2, forceKillDelay: 2)
            estimates.append(forecast.pClean)
        }
        let mean = estimates.reduce(0, +) / Double(estimates.count)
        XCTAssertEqual(mean, 0.7, accuracy: 0.05)
        let close = estimates.filter { abs($0 - 0.7) < 0.1 }.count
        XCTAssertGreaterThanOrEqual(Double(close) / Double(estimates.count), 0.7, "within 0.1 of the truth for most families")
    }

    func testHeldAndRespawnedOutcomesAreNotFailures() {
        var held = Self.report(forced: [], survivors: [10], endedEarly: false)
        held.skipForceRequested = true
        var respawned = Self.report()
        respawned.respawnedPIDs = [11]
        let refused = KillReport(displayName: "x", rootPID: 10, failures: ["This preview expired."])
        var denied = Self.report(survivors: [10], endedEarly: false)
        denied.signalDeniedPIDs = [10]

        XCTAssertEqual(KillOutcomeObservation(report: held).outcome, .excluded)
        XCTAssertEqual(KillOutcomeObservation(report: refused).outcome, .excluded)
        XCTAssertEqual(KillOutcomeObservation(report: denied).outcome, .excluded)
        XCTAssertEqual(KillOutcomeObservation(report: respawned).outcome, .respawned)

        let start = KillOutcomePosterior.empty.updating(with: Self.clean(0.4), at: Date(timeIntervalSince1970: 1))
        let after = [held, refused, denied, respawned].reduce(start) {
            $0.updating(with: KillOutcomeObservation(report: $1), at: Date(timeIntervalSince1970: 2))
        }
        XCTAssertEqual(after.cleanWeight, start.cleanWeight)
        XCTAssertEqual(after.totalWeight, start.totalWeight)
        XCTAssertEqual(after.respawnRun, 1)
        XCTAssertTrue(KillOutcomeHistory(signature: [.standard: after]).lastStopRespawned)
    }

    func testPosteriorNeverOverridesAQuitOrACarefulShutdown() {
        let gentle = Self.history(Array(repeating: Self.clean(0.3, strategy: .gentleDevServer), count: 10) +
                                  Array(repeating: Self.forced(grace: 8, strategy: .quitApp), count: 6))
        let app = PolicyFixture.evaluate(command: "/Applications/Slack.app/Contents/MacOS/Slack", name: "Slack", outcomes: gentle,
                                         path: "/Applications/Slack.app/Contents/MacOS/Slack")
        XCTAssertEqual(app.recommendation.strategy, .quitApp)
        XCTAssertGreaterThanOrEqual(app.profile.graceSeconds, 8)
    }

    func testFamilyRecordCanPreferTheOtherPoliteStrategy() {
        let record = Self.history(Array(repeating: Self.forced(), count: 3) +
                                  Array(repeating: Self.clean(0.5, strategy: .gentleDevServer), count: 6))
        let evaluation = PolicyFixture.evaluate(command: "cruncher", name: "cruncher", outcomes: record)
        XCTAssertEqual(evaluation.recommendation.strategy, .gentleDevServer)
    }

    func testNoHistorySaysSo() {
        let forecast = KillOutcomeModel(history: .empty)
            .forecast(strategy: .gentleDevServer, workloadKind: .devServer, floorSeconds: 1.2, forceKillDelay: 2)
        XCTAssertEqual(forecast.pClean, 0.76, accuracy: 1e-9)
        XCTAssertEqual(forecast.evidenceText, "No history yet; waits up to 1.2 s for a clean exit.")
        XCTAssertNil(forecast.typicalExitSeconds)
    }

    func testKindIsThePriorForANewFamily() {
        let kindOnly = Self.history(Array(repeating: Self.clean(0.6), count: 8)).signatureDropped
        let forecast = KillOutcomeModel(history: kindOnly)
            .forecast(strategy: .standard, workloadKind: .devServer, floorSeconds: 2, forceKillDelay: 2)
        XCTAssertGreaterThan(forecast.pClean, 0.62)
        XCTAssertEqual(forecast.observationCount, 0)
        XCTAssertTrue(forecast.evidenceText.hasPrefix("No history for this one yet; similar dev servers stopped cleanly 8 of 8 times"),
                      forecast.evidenceText)
    }

    // MARK: - Fixtures

    static func clean(_ seconds: TimeInterval, strategy: KillStrategy = .standard) -> KillOutcomeObservation {
        KillOutcomeObservation(strategy: strategy, outcome: .clean, latencySeconds: seconds, censored: false)
    }

    static func forced(grace: TimeInterval = 2, strategy: KillStrategy = .standard) -> KillOutcomeObservation {
        KillOutcomeObservation(strategy: strategy, outcome: .dirty, latencySeconds: grace, censored: true)
    }

    /// Folds observations into the family's and its kind's posteriors, as
    /// the store does after each stop.
    static func history(_ observations: [KillOutcomeObservation], kindToo: Bool = true) -> KillOutcomeHistory {
        var history = KillOutcomeHistory.empty
        for (index, observation) in observations.enumerated() {
            let date = Date(timeIntervalSince1970: Double(index))
            history.signature[observation.strategy] = (history.signature[observation.strategy] ?? .empty).updating(with: observation, at: date)
            if kindToo {
                history.kind[observation.strategy] = (history.kind[observation.strategy] ?? .empty).updating(with: observation, at: date)
            }
        }
        return history
    }

    static func report(forced: [Int32] = [], survivors: [Int32] = [], endedEarly: Bool = true, waited: TimeInterval = 0.4) -> KillReport {
        var report = KillReport(displayName: "x", rootPID: 10, gracefulPIDs: [10], forcedPIDs: forced, survivorPIDs: survivors,
                                attempts: [KillAttempt(pid: 10, signal: SIGTERM, stage: "graceful", succeeded: true)])
        report.graceEndedEarly = endedEarly
        report.graceWaitedSeconds = waited
        return report
    }
}

final class KillOutcomeObservationTests: XCTestCase {
    func testCleanExitWithinGraceIsMeasured() {
        let observation = KillOutcomeObservation(report: KillOutcomeModelTests.report(waited: 0.7))
        XCTAssertEqual(observation.outcome, .clean)
        XCTAssertEqual(observation.latencySeconds, 0.7)
        XCTAssertFalse(observation.censored)
    }

    func testForcedStopIsACensoredFailure() {
        let observation = KillOutcomeObservation(report: KillOutcomeModelTests.report(forced: [10], endedEarly: false, waited: 2))
        XCTAssertEqual(observation.outcome, .dirty)
        XCTAssertTrue(observation.censored)
        XCTAssertEqual(KillOutcomePosterior.bucket(for: observation), 4, "the exit would have come after 2 s")
    }

    func testWatcherlessSignalerStillProducesLatency() async {
        let table = FakeProcessTable()
        let worker = KillProcessLite.fake(pid: 740, name: "cruncher")
        table.add(worker, .exits(on: SIGTERM, afterTicks: 2))
        XCTAssertFalse(table.usesDarwinProcessNamespace, "no exit watcher runs")
        let plan = KillPlan(rootIdentity: worker.identity, targetIdentities: [worker.identity], protectedPIDs: [], displayName: "cruncher")
        let report = await ProcessKiller(snapshotProvider: table, signaler: table, currentUserID: 501, sleeper: table.sleeper)
            .kill(plan: plan, forceKillDelay: 5)
        XCTAssertTrue(report.graceEndedEarly, "the existence check ends the wait")
        XCTAssertLessThan(report.graceWaitedSeconds, 5)
        let observation = KillOutcomeObservation(report: report)
        XCTAssertEqual(observation.outcome, .clean)
        XCTAssertFalse(observation.censored)
    }

    func testDebuggedStopMeasuresNoExitLatency() async {
        let table = FakeProcessTable()
        let debugged = KillProcessLite.fake(pid: 750, name: "cruncher", flags: KillProcessLite.tracedFlag)
        table.add(debugged, .ignoresTermination)

        let report = await table.killer().kill(plan: .fixture(debugged), forceKillDelay: 5, skipForce: true)

        XCTAssertEqual(report.survivorPIDs, [750])
        XCTAssertFalse(report.graceEndedEarly, "nothing was waited on, so nothing exited early")
        XCTAssertTrue(KillOutcomeObservation(report: report).censored)
    }
}

final class KillOutcomeStoreTests: XCTestCase {
    func testPosteriorsRoundTripPerFamilyAndKind() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kill-outcomes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("radar.sqlite")
        let family = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(5))
            .enriched(classification: DevClassification(kind: .nodeServer, confidence: 1, reason: "test"))
        let store = try RadarStore(url: url)
        try await store.recordKillOperation(report: KillOutcomeModelTests.report(waited: 0.4), family: family, at: Date(timeIntervalSince1970: 10))
        var forced = KillOutcomeModelTests.report(forced: [10], endedEarly: false, waited: 2)
        forced.strategyUsed = .standard
        try await store.recordKillOperation(report: forced, family: family, at: Date(timeIntervalSince1970: 11))
        var held = KillOutcomeModelTests.report(survivors: [10], endedEarly: false)
        held.skipForceRequested = true
        try await store.recordKillOperation(report: held, family: family, at: Date(timeIntervalSince1970: 12))

        let reopened = try RadarStore(url: url)
        let history = try await reopened.killOutcomeHistory(signatureID: family.signature.id, devKind: "nodeServer")
        let posterior = try XCTUnwrap(history.signature[.standard])
        XCTAssertEqual(posterior.observationCount, 2, "the held stop is not an outcome")
        XCTAssertEqual(posterior.cleanWeight, 0.9, accuracy: 1e-9)
        XCTAssertEqual(posterior.totalWeight, 1.9, accuracy: 1e-9)
        XCTAssertEqual(posterior.censoredRun, 1)
        XCTAssertEqual(posterior.cleanCount, 1)
        XCTAssertEqual(posterior.latencyBuckets.count, 8)
        XCTAssertEqual(history.kind[.standard], posterior, "the kind row saw the same stops")
        let other = try await reopened.killOutcomeHistory(signatureID: "another", devKind: "nodeServer")
        XCTAssertNil(other.signature[.standard])
        XCTAssertEqual(other.kind[.standard]?.observationCount, 2)
    }

    func testAStopOfAnotherProcessIsAuditedButNotLearned() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kill-outcomes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let family = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(5))
            .enriched(classification: DevClassification(kind: .nodeServer, confidence: 1, reason: "test"))
        let store = try RadarStore(url: folder.appendingPathComponent("radar.sqlite"))
        var supervisorStop = KillReport(displayName: "PM2", rootPID: 499, gracefulPIDs: [499], forcedPIDs: [499],
                                        attempts: [KillAttempt(pid: 499, signal: SIGTERM, stage: "graceful", succeeded: true)])
        supervisorStop.graceWaitedSeconds = 2
        try await store.recordKillOperation(report: supervisorStop, family: family, learnsFromOutcome: false)

        let history = try await store.killOutcomeHistory(signatureID: family.signature.id, devKind: "nodeServer")
        XCTAssertEqual(history, .empty, "stopping PM2 says nothing about how the server stops")
        let audit = try await store.recentKillOperations()
        XCTAssertEqual(audit.map(\.displayName), ["PM2"])
    }
}

/// A small deterministic generator, so the convergence test is repeatable.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 33)
    }
}

private extension KillOutcomeHistory {
    var signatureDropped: KillOutcomeHistory {
        KillOutcomeHistory(signature: [:], kind: kind)
    }
}
