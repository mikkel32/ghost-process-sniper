import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

/// Saved settings must survive a launch whose first store call fails or is
/// slow: an edit made before they load is merged onto them, never saved over
/// them with the defaults.
@MainActor
final class SettingsLoadGateTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    nonisolated override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    nonisolated override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTransientOpenFailureAtLaunchDoesNotLetTheFirstEditOverwriteSavedSettings() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let custom = customSettings()
        try makeUnversionedStore(at: url, settings: custom)
        // Another connection holds the write lock, so the pending migrations cannot start.
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let clock = SettingsTestClock(Date(timeIntervalSince1970: 1_000))
        let monitor = makeMonitor(store: RadarStore(url: url, busyTimeoutMilliseconds: 10, clock: { clock.now }))
        monitor.start()
        let failed = await waitUntil { monitor.storeError != nil }
        XCTAssertTrue(failed, "the launch load should have failed")
        monitor.stop()
        XCTAssertEqual(monitor.settings, .smart, "running on defaults until the load succeeds")

        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT", nil, nil, nil), SQLITE_OK)
        sqlite3_close(blocker)
        clock.now = Date(timeIntervalSince1970: 1_040)

        monitor.settings.forceKillDelay = 3
        monitor.saveSettingsDebounced(delay: 0)
        let merged = await waitUntil { monitor.settings.cpuPercent == custom.cpuPercent }
        XCTAssertTrue(merged, "the save should load the stored settings first")
        await monitor.settingsSaveTask?.value

        var expected = custom
        expected.forceKillDelay = 3
        XCTAssertEqual(monitor.settings, expected)
        let persisted = try await RadarStore(url: url).loadSettings(defaults: .aggressive)
        XCTAssertEqual(persisted, expected, "only the edited field may change on disk")
    }

    func testEditDuringASlowFirstOpenIsMergedOntoTheSavedSettings() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let custom = customSettings()
        try makeUnversionedStore(at: url, settings: custom)
        // The first open waits on a lock for 0.6 s.
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let held = UInt(bitPattern: blocker)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            sqlite3_exec(OpaquePointer(bitPattern: held), "COMMIT", nil, nil, nil)
        }
        defer { sqlite3_close(blocker) }

        let monitor = makeMonitor(store: RadarStore(url: url, busyTimeoutMilliseconds: 5_000, clock: { Date() }))
        monitor.start()
        try await Task.sleep(for: .milliseconds(100))
        monitor.settings.forceKillDelay = 7
        monitor.saveSettingsDebounced(delay: 0)
        let loaded = await waitUntil { monitor.settings.cpuPercent == custom.cpuPercent }
        XCTAssertTrue(loaded)
        await monitor.settingsSaveTask?.value
        monitor.stop()

        var expected = custom
        expected.forceKillDelay = 7
        XCTAssertEqual(monitor.settings, expected, "the late load must not revert the edit")
        let persisted = try await RadarStore(url: url).loadSettings(defaults: .aggressive)
        XCTAssertEqual(persisted, expected, "the edit is saved on top of the stored settings")
    }

    func testTheLoopRetriesAFailedLaunchLoad() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let custom = customSettings()
        try makeUnversionedStore(at: url, settings: custom)
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let clock = SettingsTestClock(Date(timeIntervalSince1970: 1_000))
        let monitor = makeMonitor(store: RadarStore(url: url, busyTimeoutMilliseconds: 10, clock: { clock.now }))
        monitor.start()
        defer { monitor.stop() }
        let failed = await waitUntil { monitor.storeError != nil }
        XCTAssertTrue(failed)

        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT", nil, nil, nil), SQLITE_OK)
        sqlite3_close(blocker)
        clock.now = Date(timeIntervalSince1970: 1_040)
        // Opening the popover runs the next tick now.
        monitor.setPopoverVisible(true)
        let loaded = await waitUntil { monitor.settings == custom }
        XCTAssertTrue(loaded, "a later tick should load the stored settings")
    }

    func testShutdownMergesAPendingEditOntoSettingsThatFailedToLoadAtLaunch() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let custom = customSettings()
        try makeUnversionedStore(at: url, settings: custom)
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let clock = SettingsTestClock(Date(timeIntervalSince1970: 1_000))
        let monitor = makeMonitor(store: RadarStore(url: url, busyTimeoutMilliseconds: 10, clock: { clock.now }))
        monitor.start()
        let failed = await waitUntil { monitor.storeError != nil }
        XCTAssertTrue(failed)
        monitor.settings.memoryBytes = 5_000_000_000
        monitor.saveSettingsDebounced(delay: 60)
        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT", nil, nil, nil), SQLITE_OK)
        sqlite3_close(blocker)
        clock.now = Date(timeIntervalSince1970: 1_040)
        await monitor.shutdown()

        var expected = custom
        expected.memoryBytes = 5_000_000_000
        let persisted = try await RadarStore(url: url).loadSettings(defaults: .aggressive)
        XCTAssertEqual(persisted, expected, "quitting saves the edit, never the defaults around it")
    }

    func testShutdownInsideTheRetryCooldownLeavesTheStoredSettingsAlone() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let custom = customSettings()
        try makeUnversionedStore(at: url, settings: custom)
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let clock = SettingsTestClock(Date(timeIntervalSince1970: 1_000))
        let monitor = makeMonitor(store: RadarStore(url: url, busyTimeoutMilliseconds: 10, clock: { clock.now }))
        monitor.start()
        let failed = await waitUntil { monitor.storeError != nil }
        XCTAssertTrue(failed)
        monitor.settings.memoryBytes = 5_000_000_000
        monitor.saveSettingsDebounced(delay: 60)
        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT", nil, nil, nil), SQLITE_OK)
        sqlite3_close(blocker)
        await monitor.shutdown()

        let persisted = try await RadarStore(url: url).loadSettings(defaults: .aggressive)
        XCTAssertEqual(persisted, custom, "an edit that could not be merged is dropped, not saved over them")
    }

    func testStoreRefusesToOverwriteSettingsItNeverRead() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let custom = customSettings()
        try await RadarStore(url: url).saveSettings(custom)

        let store = RadarStore(url: url)
        var edited = ThresholdSettings.smart
        edited.forceKillDelay = 4
        do {
            try await store.saveSettings(edited)
            XCTFail("a blind save must not replace stored settings")
        } catch {}
        let persisted = try await store.loadSettings(defaults: .aggressive)
        XCTAssertEqual(persisted, custom)

        try await store.saveSettings(edited)
        let saved = try await RadarStore(url: url).loadSettings(defaults: .aggressive)
        XCTAssertEqual(saved, edited, "after a read the store saves normally")
    }

    func testAnUnstartedMonitorStillPersistsAnEditToAnEmptyStore() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        let monitor = makeMonitor(store: RadarStore(url: url))
        monitor.settings.memoryBytes = 321_000_000
        monitor.saveSettingsDebounced(delay: 0)
        await monitor.settingsSaveTask?.value

        let persisted = try await RadarStore(url: url).loadSettings(defaults: .aggressive)
        XCTAssertEqual(persisted.memoryBytes, 321_000_000)
    }

    func testMergeCarriesEveryEditedFieldAndNothingElse() {
        let stored = customSettings()
        XCTAssertEqual(ThresholdSettings.smart.edits(since: .smart, appliedTo: stored), stored)

        var edited = ThresholdSettings.smart
        edited.memoryBytes = 7_000_000
        edited.cpuPercent = 12
        edited.leakVelocityMegabytesPerMinute = 3
        edited.refreshInterval = 9
        edited.forceKillDelay = 6
        edited.radarMode = .heavy
        edited.groupFamilies = false
        edited.performanceMode = .batterySaver
        edited.detectionMode = .custom
        edited.sensitivity = .proactive
        edited.adaptivePerformance = false
        edited.notifications = NotificationPreferences(families: false, energy: false, security: .dangerousOnly)
        XCTAssertEqual(edited.edits(since: .smart, appliedTo: stored), edited)

        var one = ThresholdSettings.smart
        one.groupFamilies = false
        var expected = stored
        expected.groupFamilies = false
        XCTAssertEqual(one.edits(since: .smart, appliedTo: stored), expected)
    }

    func testANotificationChoiceMadeBeforeTheSettingsLoadedSurvivesTheMerge() {
        let stored = customSettings()
        var edited = ThresholdSettings.smart
        edited.notifications.energy = false
        var expected = stored
        expected.notifications.energy = false
        XCTAssertEqual(edited.edits(since: .smart, appliedTo: stored), expected)
    }

    private func customSettings() -> ThresholdSettings {
        var custom = ThresholdSettings.smart
        custom.memoryBytes = 3_000_000_000
        custom.cpuPercent = 250
        custom.refreshInterval = 4
        custom.radarMode = .all
        return custom
    }

    private func makeMonitor(store: RadarStore) -> ProcessMonitor {
        ProcessMonitor(sampler: GatedSampler(), builder: ProcessFamilyBuilder(currentUserID: 501),
                       settings: .smart, store: store, thermalSampler: ThermalSampler())
    }

    /// A store an older release wrote: unversioned, in WAL mode, with custom
    /// settings. Opening it runs every migration.
    private func makeUnversionedStore(at url: URL, settings: ThresholdSettings) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode = WAL", nil, nil, nil), SQLITE_OK)
        for sql in RadarStoreSchema.migrationStatements {
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
        let json = try StoreCodec().encode(settings).replacingOccurrences(of: "'", with: "''")
        let insert = "INSERT INTO settings(key, json, updated_at) VALUES('thresholds', '\(json)', 1)"
        XCTAssertEqual(sqlite3_exec(handle, insert, nil, nil, nil), SQLITE_OK)
    }
}

private final class SettingsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
