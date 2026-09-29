import XCTest
@testable import GhostProcessSniperCore

final class AlertMemoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    /// Stands in for the user's defaults, so no test writes to the real ones.
    private final class Shelf: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        var store: AlertMemoryStore {
            AlertMemoryStore(read: { key in self.lock.withLock { self.values[key] } },
                             write: { data, key in self.lock.withLock { self.values[key] = data } })
        }

        func put(_ data: Data, forKey key: String) { lock.withLock { values[key] = data } }
        var keys: Set<String> { lock.withLock { Set(values.keys) } }
    }

    func testTheHashIsStableAndHidesTheKey() {
        XCTAssertEqual(AlertMemory.hash("/tmp/x|temporaryLocation|suspicious").count, 64)
        XCTAssertEqual(AlertMemory.hash("a"), AlertMemory.hash("a"))
        XCTAssertNotEqual(AlertMemory.hash("a"), AlertMemory.hash("b"))
        XCTAssertEqual(AlertMemory.hash("a"), "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
                       "SHA-256, so a saved memory stays valid across releases")
    }

    func testMemoryRoundTripsThroughJSON() throws {
        let memory = AlertMemory(lastAlerted: [AlertMemory.hash("a"): now, AlertMemory.hash("b"): now.addingTimeInterval(60)])
        let decoded = try JSONDecoder().decode(AlertMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(decoded, memory)
    }

    func testTheStoreSavesEachGatesMemorySeparately() {
        let shelf = Shelf()
        let sentinel = AlertMemory(lastAlerted: [AlertMemory.hash("s"): now])
        let energy = AlertMemory(lastAlerted: [AlertMemory.hash("e"): now])
        shelf.store.save(sentinel, for: .sentinel)
        shelf.store.save(energy, for: .energy)
        XCTAssertEqual(shelf.store.load(.sentinel), sentinel)
        XCTAssertEqual(shelf.store.load(.energy), energy)
        XCTAssertEqual(shelf.keys, ["Alerts.sentinel.v1", "Alerts.energy.v1"])
    }

    func testAnUnreadableSavedMemoryIsAnEmptyOne() {
        let shelf = Shelf()
        XCTAssertEqual(shelf.store.load(.sentinel), AlertMemory(), "nothing saved yet")
        shelf.put(Data("not json".utf8), forKey: "Alerts.sentinel.v1")
        shelf.put(Data(#"{"lastAlerted": {"x": "yesterday"}}"#.utf8), forKey: "Alerts.energy.v1")
        XCTAssertEqual(shelf.store.load(.sentinel), AlertMemory())
        XCTAssertEqual(shelf.store.load(.energy), AlertMemory())
    }
}
