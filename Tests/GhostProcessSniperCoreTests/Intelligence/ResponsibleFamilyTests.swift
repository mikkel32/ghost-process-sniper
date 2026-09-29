import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// A browser's tabs, GPU and network processes are started by launchd, so
/// their parent is pid 1 and the process tree alone leaves each one a family
/// of its own. macOS knows which app they work for: they join that app's
/// family, and only when every safeguard below agrees.
final class ResponsibleFamilyTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private static let mib = Fixture.mib
    private static let safariPath = "/Applications/Safari.app/Contents/MacOS/Safari"
    private static let webKit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices"
    private static let terminalPath = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"

    // MARK: - Joining the app

    func testTabsJoinTheAppMacOSHoldsResponsibleForThem() throws {
        let app = safari()
        let tabs = [tab(510), tab(511), tab(512)]
        let families = build([app] + tabs, responsible: hints(tabs, to: app))

        XCTAssertEqual(families.count, 1)
        let family = try XCTUnwrap(families.first)
        XCTAssertEqual(family.root.pid, 500)
        XCTAssertEqual(family.displayName, "Safari")
        XCTAssertEqual(family.members.map(\.pid).sorted(), [500, 510, 511, 512])
        XCTAssertEqual(family.totalPhysicalFootprintBytes, 2_400 * Self.mib)
        XCTAssertEqual(family.childCount, 3)
    }

    func testGraphicsAndNetworkingProcessesJoinToo() throws {
        let app = safari()
        let helpers = [tab(510), xpc(511, "com.apple.WebKit.GPU", megabytes: 400), xpc(512, "com.apple.WebKit.Networking", megabytes: 90)]
        let families = build([app] + helpers, responsible: hints(helpers, to: app), mode: .all)

        XCTAssertEqual(families.count, 1)
        XCTAssertEqual(families.first?.members.map(\.pid).sorted(), [500, 510, 511, 512])
    }

    /// Nothing changes for a sample with no hints, which is every sample the
    /// lookup could not answer for.
    func testTheSameSampleWithoutHintsLeavesEveryTabAlone() {
        let app = safari()
        let families = build([app] + [tab(510), tab(511), tab(512)])

        XCTAssertEqual(Set(families.map(\.root.pid)), [510, 511, 512], "Safari at 300 MB is under the heavy-mode gate")
        XCTAssertTrue(families.allSatisfy { $0.linkedIdentities.isEmpty })
    }

    /// Rules, snoozes and learned baselines are keyed by the family's
    /// signature and root; folding tabs in must not orphan them.
    func testTheAppKeepsItsKeyWhenTabsJoin() throws {
        let app = safari()
        let tabs = [tab(510), tab(511)]
        let alone = try XCTUnwrap(build([app], mode: .all).first)
        let withTabs = try XCTUnwrap(build([app] + tabs, responsible: hints(tabs, to: app), mode: .all).first)

        XCTAssertEqual(withTabs.familyKey, alone.familyKey)
        XCTAssertEqual(withTabs.signature.id, alone.signature.id)
        XCTAssertGreaterThan(withTabs.totalPhysicalFootprintBytes, alone.totalPhysicalFootprintBytes)
    }

    /// The "group families" setting off means every process stands alone,
    /// hinted or not.
    func testWithGroupingOffEveryProcessStaysItsOwnFamily() {
        let app = safari()
        let tabs = [tab(510), tab(511)]
        let families = build([app] + tabs, responsible: hints(tabs, to: app), mode: .all, groupFamilies: false)

        XCTAssertEqual(Set(families.map(\.root.pid)), [500, 510, 511])
        XCTAssertTrue(families.allSatisfy { $0.members.count == 1 && $0.linkedIdentities.isEmpty })
    }

    // MARK: - Stopping

    /// The stop preview locks anything outside the root's own process tree,
    /// so the family's plan names the app alone; the tabs go when it quits.
    func testStoppingTheFamilyAsksTheAppToQuitAndLocksNothing() async throws {
        let app = safari()
        let tabs = [tab(510), tab(511)]
        let family = try XCTUnwrap(build([app] + tabs, responsible: hints(tabs, to: app)).first)

        XCTAssertEqual(family.ownedIdentities, [app.identity])
        XCTAssertEqual(Set(family.linkedIdentities), Set(tabs.map(\.identity)))
        XCTAssertEqual(family.killPlan().targetIdentities, [app.identity])
        XCTAssertTrue(family.protectedPIDs.isEmpty)
        XCTAssertTrue(family.isKillable)

        let preview = await table([app] + tabs).killer().preview(plan: family.killPlan(), forceKillDelay: 2)
        XCTAssertEqual(preview.targetPIDs, [500])
        XCTAssertTrue(preview.lockedTargets.isEmpty, "\(preview.lockedTargets.map(\.reason))")
        XCTAssertEqual(preview.strategyRecommendation.strategy, .quitApp)
    }

    /// Only the linked side is left out: the app's own children stay in its
    /// plan, stopped before it as always.
    func testTheAppsOwnChildrenStayInItsPlan() throws {
        let app = safari()
        let path = "/Applications/Safari.app/Contents/Frameworks/Safari Helper.app/Contents/MacOS/Safari Helper"
        let child = Fixture.process(pid: 501, parent: 500, name: "Safari Helper", path: path, command: path, megabytes: 50)
        let tabs = [tab(510)]
        let family = try XCTUnwrap(build([app, child] + tabs, responsible: hints(tabs, to: app), mode: .all).first)

        XCTAssertEqual(family.ownedIdentities, [child.identity, app.identity])
        XCTAssertEqual(family.linkedIdentities, [tabs[0].identity])
    }

    /// Why linked tabs stay out of the family plan: named in it, they would
    /// all be refused as outside the app's tree.
    func testATabNamedInTheFamilyPlanWouldBeLocked() async throws {
        let app = safari()
        let tabs = [tab(510)]
        let family = try XCTUnwrap(build([app] + tabs, responsible: hints(tabs, to: app)).first)
        let plan = family.killPlan()
        let widened = KillPlan(rootIdentity: plan.rootIdentity, targetIdentities: plan.targetIdentities + [tabs[0].identity],
                               protectedPIDs: plan.protectedPIDs, displayName: plan.displayName)

        let preview = await table([app] + tabs).killer().preview(plan: widened, forceKillDelay: 2)
        XCTAssertEqual(preview.lockedTargets.map(\.reason), ["Outside selected family tree"])
    }

    func testATabCanStillBeStoppedOnItsOwn() async throws {
        let app = safari()
        let tabs = [tab(510), tab(511)]
        let family = try XCTUnwrap(build([app] + tabs, responsible: hints(tabs, to: app)).first)

        XCTAssertTrue(family.canStopIndividually(tabs[0].identity))
        XCTAssertTrue(family.canStopIndividually(app.identity))
        XCTAssertFalse(family.canStopIndividually(other().identity))

        let preview = await table([app] + tabs).killer().preview(plan: family.killPlan().targetingOnly(tabs[0]), forceKillDelay: 2)
        XCTAssertEqual(preview.targetPIDs, [510])
        XCTAssertTrue(preview.lockedTargets.isEmpty, "\(preview.lockedTargets.map(\.reason))")
    }

    func testTheTreeShowsEveryTabUnderTheAppAndOffersToStopEach() throws {
        let app = safari()
        let tabs = [tab(510), tab(511), tab(512)]
        let family = try XCTUnwrap(build([app] + tabs, responsible: hints(tabs, to: app)).first)

        let rows = FamilyDetailPanelModel(family: family).processTree
        let root = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(root.id, app.identity)
        XCTAssertTrue(root.isStoppable)
        XCTAssertEqual(Set(root.children?.map(\.id) ?? []), Set(tabs.map(\.identity)))
        XCTAssertEqual(root.children?.map(\.isStoppable), [true, true, true])
    }

    /// The culprit of a leak can be a tab that is not in the app's own tree;
    /// stopping only it is still the offer that spares the rest.
    func testALeakingTabIsOfferedAsTheOnlyThingToStop() throws {
        let app = safari(megabytes: 400)
        let cadence: TimeInterval = 3
        let ticks = 50
        var pipeline = RadarPipeline(
            builder: ProcessFamilyBuilder(currentUserID: 501, processorCount: 8),
            intelligence: RadarIntelligence(forecaster: FamilyRiskForecaster(processorCount: 8, physicalMemoryBytes: 16 << 30))
        )
        var settings = ThresholdSettings.smart
        settings.radarMode = .heavy
        let context = RadarContext(baselines: [:], recentIncidentCounts: [:], rules: [])
        var last: [ProcessFamily] = []
        for index in 0..<ticks {
            let date = Fixture.now.addingTimeInterval(-Double(ticks - 1 - index) * cadence)
            let minutes = Double(index) * cadence / 60
            let tabs = [tab(510, megabytes: 700 + 800 * minutes, date: date), tab(511, megabytes: 650, date: date)]
            last = pipeline.run(processes: [safari(megabytes: 400, date: date)] + tabs, settings: settings, context: context,
                                responsible: hints(tabs, to: app), now: date).families
        }

        let family = try XCTUnwrap(last.first)
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(family.culprit?.identity.pid, 510, "growth: \(family.growth.map { "\($0.name) \($0.share)" })")
        XCTAssertTrue(family.suggestions.contains { $0.title.hasPrefix("Stop only com.apple.WebKit.WebContent") },
                      family.suggestions.map(\.title).joined(separator: " | "))
    }

    // MARK: - Finding it

    func testSearchFindsTheAppByNameAndItsTabsByTheirProcessName() throws {
        let app = safari()
        let tabs = [tab(510), tab(511)]
        let family = try XCTUnwrap(build([app] + tabs, responsible: hints(tabs, to: app)).first)

        for query in ["safari", "webcontent"] {
            let result = project(query, family: family)
            XCTAssertEqual(result.familyRows.map(\.familyKey), [family.familyKey], query)
            XCTAssertTrue(result.search.processRows.isEmpty, "a tab inside the family is never listed again as untracked")
        }
        let reason = project("webcontent", family: family).search.familyMatches[family.familyKey]?.reason ?? ""
        XCTAssertTrue(reason.contains("com.apple.WebKit.WebContent"), reason)
    }

    // MARK: - Safeguards

    /// An orphaned dev server is not a service, whatever app macOS holds
    /// responsible: it stays its own family, forgotten or not.
    func testAnOrphanedDevServerNeverFoldsIntoTheAppItWasStartedFrom() {
        for ownerPath in [Self.terminalPath, "/Applications/Cursor.app/Contents/MacOS/Cursor"] {
            let owner = Fixture.process(pid: 400, name: "Owner", path: ownerPath, command: ownerPath, megabytes: 300)
            let server = Fixture.process(pid: 600, name: "node", path: "/usr/local/bin/node",
                                         command: "node /Users/dev/api/server.js", megabytes: 900)
            let families = build([owner, server], responsible: [server.identity: 400], mode: .all)
            XCTAssertTrue(standsAlone(600, in: families), ownerPath)
        }
    }

    func testATerminalNeverOwnsEvenAServiceStylePath() {
        let terminal = Fixture.process(pid: 400, name: "Terminal", path: Self.terminalPath, command: Self.terminalPath, megabytes: 200)
        let helper = tab(510)
        XCTAssertTrue(standsAlone(510, in: build([terminal, helper], responsible: hints([helper], to: terminal))))
    }

    func testOnlyAnAppMainBinaryCanOwn() {
        let helper = tab(510)
        let runner = Fixture.process(pid: 400, name: "node", path: "/usr/local/bin/node", command: "node runner.js", megabytes: 200)
        XCTAssertTrue(standsAlone(510, in: build([runner, helper], responsible: hints([helper], to: runner))))

        let renderer = Fixture.process(
            pid: 401, name: "Safari Helper (Renderer)",
            path: "/Applications/Safari.app/Contents/Frameworks/Safari Helper (Renderer).app/Contents/MacOS/Safari Helper (Renderer)",
            command: "Safari Helper (Renderer)", megabytes: 200)
        XCTAssertTrue(standsAlone(510, in: build([renderer, helper], responsible: hints([helper], to: renderer))))
    }

    /// A pid that has been reused since would name a stranger.
    func testAnOwnerThatStartedAfterTheHelperIsIgnored() {
        let helper = tab(510)
        let late = safari(started: Fixture.now.addingTimeInterval(-60))
        XCTAssertTrue(standsAlone(510, in: build([late, helper], responsible: hints([helper], to: late))))

        let early = safari(started: Fixture.now.addingTimeInterval(-7_200))
        XCTAssertFalse(standsAlone(510, in: build([early, helper], responsible: hints([helper], to: early))))
    }

    func testAnOwnerBelongingToAnotherUserIsIgnored() {
        let app = safari()
        let theirs = foreign(tab(510))
        XCTAssertTrue(standsAlone(510, in: build([app, theirs], responsible: hints([theirs], to: app), mode: .all)))

        let system = foreign(safari())
        let mine = tab(511)
        XCTAssertTrue(standsAlone(511, in: build([system, mine], responsible: hints([mine], to: system), mode: .all)))
    }

    func testAHintNamingNothingInTheSampleIsIgnored() {
        let helper = tab(510)
        XCTAssertTrue(standsAlone(510, in: build([helper], responsible: [helper.identity: 999])))
    }

    /// Only launchd's own children are placed by the hint; a process with a
    /// real parent already has one.
    func testAHelperWithARealParentKeepsIt() throws {
        let app = safari()
        let parent = Fixture.process(pid: 450, name: "node", path: "/usr/local/bin/node", command: "node runner.js", megabytes: 100)
        let helper = tab(510, parent: 450)
        let families = build([app, parent, helper], responsible: hints([helper], to: app), mode: .all)

        let own = try XCTUnwrap(families.first { $0.members.contains { $0.pid == 510 } })
        XCTAssertEqual(own.root.pid, 450)
        XCTAssertTrue(own.linkedIdentities.isEmpty)
    }

    /// A language server the app started is a workload of its own, not part
    /// of the app; the same holds when macOS reports the app as responsible.
    func testAServiceWorkloadStaysItsOwnFamily() throws {
        let xcode = Fixture.process(pid: 520, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode",
                                    command: "Xcode", megabytes: 900)
        let path = "\(Self.webKit)/com.example.sourcekit-lsp.xpc/Contents/MacOS/sourcekit-lsp"
        let server = Fixture.process(pid: 521, name: "sourcekit-lsp", path: path, command: "sourcekit-lsp", megabytes: 700)
        let families = build([xcode, server], responsible: hints([server], to: xcode), mode: .all)

        XCTAssertTrue(standsAlone(521, in: families))
        XCTAssertEqual(families.first { $0.root.pid == 521 }?.classification?.kind, .languageServer)
        XCTAssertTrue(standsAlone(520, in: families))
    }

    // MARK: - The refresh worker

    /// The worker asks macOS once per launchd-started helper, before it
    /// builds families, and hands the same answers to the energy attribution.
    func testTheWorkerBuildsFamiliesWithTheHintsItAlsoGivesTheEnergyPage() async throws {
        let log = QueryLog()
        let worker = RadarRefreshWorker(store: nil, builder: ProcessFamilyBuilder(currentUserID: 501), battery: nil,
                                        sleepAssertions: nil, responsibleQuery: { pid in log.record(pid) ? 500 : nil })
        var settings = ThresholdSettings.smart
        settings.radarMode = .heavy
        var outcome: RefreshOutcome?
        for tick in 0..<2 {
            let date = Fixture.now.addingTimeInterval(Double(tick) * 5)
            let processes = [safari(date: date), tab(510, cpu: 15, date: date), tab(511, cpu: 12, date: date)]
            let request = RefreshRequest(settings: settings, currentFamilies: [], currentIncidents: [], currentStoreHealth: .empty,
                                         uiVisible: true, focusedSignatureIDs: [], now: date, startedAt: date)
            outcome = await worker.ingest(batch: ProcessSampleBatch(processes: processes, sampledAt: date, stats: .empty),
                                          request: request)
        }

        let result = try XCTUnwrap(outcome)
        XCTAssertEqual(result.families.map(\.root.pid), [500])
        XCTAssertEqual(result.families.first?.members.map(\.pid).sorted(), [500, 510, 511])
        XCTAssertEqual(result.thermalActivity.contributors.map(\.displayName), ["Safari"], "the energy page agrees")
        XCTAssertEqual(log.pids.sorted(), [510, 511], "asked once per helper, not once per tick or per consumer")
    }

    // MARK: - Fixtures

    private func safari(pid: Int32 = 500, megabytes: Double = 300, started: Date? = nil, date: Date? = nil) -> ProcessMetrics {
        Fixture.process(pid: pid, name: "Safari", path: Self.safariPath, command: Self.safariPath, megabytes: megabytes,
                        started: started, date: date)
    }

    private func tab(_ pid: Int32, parent: Int32 = 1, megabytes: Double = 700, cpu: Double = 0, date: Date? = nil) -> ProcessMetrics {
        xpc(pid, "com.apple.WebKit.WebContent", parent: parent, megabytes: megabytes, cpu: cpu, date: date)
    }

    private func xpc(_ pid: Int32, _ name: String, parent: Int32 = 1, megabytes: Double, cpu: Double = 0, date: Date? = nil) -> ProcessMetrics {
        let path = "\(Self.webKit)/\(name).xpc/Contents/MacOS/\(name)"
        return Fixture.process(pid: pid, parent: parent, name: name, path: path, command: path, megabytes: megabytes, cpu: cpu, date: date)
    }

    private func other() -> ProcessMetrics {
        Fixture.process(pid: 900, name: "node", path: "/usr/local/bin/node", megabytes: 10)
    }

    /// The same process owned by root.
    private func foreign(_ process: ProcessMetrics) -> ProcessMetrics {
        ProcessMetrics(
            identity: process.identity, parentPID: process.parentPID, userID: 0, ownerName: "root", name: process.name,
            executablePath: process.executablePath, commandLine: process.commandLine,
            residentMemoryBytes: process.residentMemoryBytes, physicalFootprintBytes: process.physicalFootprintBytes,
            virtualMemoryBytes: process.virtualMemoryBytes, cpuPercent: process.cpuPercent, totalProcessorSeconds: 0,
            threadCount: process.threadCount, isSystemProcess: false, sampledAt: process.sampledAt)
    }

    private func hints(_ helpers: [ProcessMetrics], to owner: ProcessMetrics) -> [ProcessIdentity: Int32] {
        Dictionary(uniqueKeysWithValues: helpers.map { ($0.identity, owner.pid) })
    }

    private func build(
        _ processes: [ProcessMetrics],
        responsible: [ProcessIdentity: Int32] = [:],
        mode: RadarMode = .heavy,
        groupFamilies: Bool = true
    ) -> [ProcessFamily] {
        var settings = ThresholdSettings.smart
        settings.radarMode = mode
        settings.groupFamilies = groupFamilies
        var window = TrendWindow()
        return ProcessFamilyBuilder(currentUserID: 501)
            .buildFamilies(from: processes, settings: settings, trendWindow: &window, responsible: responsible, now: Fixture.now)
            .map { RadarIntelligence().enrich(family: $0, context: RadarContext(baselines: [:], recentIncidentCounts: [:], rules: []),
                                              settings: settings, now: Fixture.now) }
    }

    /// Whether `pid` is the only member of the family that holds it.
    private func standsAlone(_ pid: Int32, in families: [ProcessFamily]) -> Bool {
        guard let family = families.first(where: { $0.members.contains { $0.pid == pid } }) else { return false }
        return family.root.pid == pid && family.members.count == 1 && family.linkedIdentities.isEmpty
    }

    private func table(_ processes: [ProcessMetrics]) -> FakeProcessTable {
        let table = FakeProcessTable()
        for process in processes {
            table.add(KillProcessLite(process: process, status: 2, processGroupID: process.pid))
        }
        return table
    }

    private func project(_ text: String, family: ProcessFamily) -> ConsoleDerivedSnapshot {
        var state = RadarConsoleState.default
        state.searchText = text
        let snapshot = RadarConsoleSnapshot.build(
            families: [family], summary: ProcessFamilyBuilder(currentUserID: 501).summary(for: [family]), incidents: [], rules: [],
            metrics: .empty, health: .starting, storeHealth: .empty, storeError: nil, previous: nil, generatedAt: Fixture.now)
        var cache = ConsoleDerivedSnapshotCache()
        return cache.update(ConsoleProjectionRequest(source: snapshot, incidents: [], state: state, families: [family],
                                                     processes: family.members, sampleRevision: 1))
    }

    /// Records the pids the injected lookup was asked about. The refresh
    /// worker is an actor and the query is `@Sendable`, so it is locked.
    private final class QueryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [Int32] = []

        var pids: [Int32] { lock.withLock { asked } }

        /// True for a tab, whose responsible pid the test names as 500.
        func record(_ pid: Int32) -> Bool {
            lock.withLock { asked.append(pid) }
            return pid >= 510
        }
    }
}
