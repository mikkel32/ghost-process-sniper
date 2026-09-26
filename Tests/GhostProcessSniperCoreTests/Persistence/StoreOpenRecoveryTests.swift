import Foundation
import SQLite3
import XCTest
@testable import GhostProcessSniperCore

final class StoreOpenRecoveryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCorruptFileIsMovedAsideAndReplacedWithAFreshStore() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        var generator = SystemRandomNumberGenerator()
        let garbage = Data((0..<4_096).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try garbage.write(to: url)

        let store = RadarStore(url: url)
        _ = try await store.context(for: [], settings: .smart, now: Date())

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("Radar.corrupt-") && $0.hasSuffix(".sqlite") }, "\(names)")
        let health = await store.storeHealth()
        XCTAssertTrue(health.recoveredFromCorruption)
        XCTAssertNil(health.errorMessage)

        var settings = ThresholdSettings.smart
        settings.memoryBytes = 77_000_000
        try await store.saveSettings(settings)
        let loaded = try await store.loadSettings(defaults: .smart)
        XCTAssertEqual(loaded.memoryBytes, 77_000_000)
    }

    func testLockedStoreReportsTheErrorAndRetriesAfterTheCooldown() async throws {
        let url = folder.appendingPathComponent("Radar.sqlite")
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "CREATE TABLE held(id INTEGER)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)

        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let store = RadarStore(url: url, busyTimeoutMilliseconds: 10, clock: { clock.now })
        do {
            _ = try await store.loadSettings(defaults: .smart)
            XCTFail("a locked database must not open")
        } catch {}
        let failed = await store.storeHealth()
        XCTAssertNotNil(failed.errorMessage)
        XCTAssertFalse(failed.recoveredFromCorruption)

        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT", nil, nil, nil), SQLITE_OK)
        clock.now = Date(timeIntervalSince1970: 1_010)
        do {
            _ = try await store.loadSettings(defaults: .smart)
            XCTFail("the store must not retry inside the cooldown")
        } catch {}

        clock.now = Date(timeIntervalSince1970: 1_031)
        _ = try await store.loadSettings(defaults: .smart)
        let recovered = await store.storeHealth()
        XCTAssertNil(recovered.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class TestClock: @unchecked Sendable {
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
