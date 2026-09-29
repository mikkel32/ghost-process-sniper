import XCTest
@testable import GhostProcessSniperCore

/// Microphone and camera listeners follow their devices one to one.
final class ListenerSetTests: XCTestCase {
    private final class Registrar {
        var added: [UInt32] = []
        var removed: [UInt32] = []
        var refusing: Set<UInt32> = []
        /// Listeners still registered per device: adds minus removes.
        var live: [UInt32: Int] {
            var counts: [UInt32: Int] = [:]
            for id in added { counts[id, default: 0] += 1 }
            for id in removed { counts[id, default: 0] -= 1 }
            return counts.filter { $0.value != 0 }
        }
    }

    private func sync(_ set: inout ListenerSet<UInt32>, _ wanted: Set<UInt32>, _ registrar: Registrar) {
        set.sync(to: wanted, add: { id in
            guard !registrar.refusing.contains(id) else { return false }
            registrar.added.append(id)
            return true
        }, remove: { registrar.removed.append($0) })
    }

    func testSwitchingInputsBackAndForthLeavesOneListener() {
        var set = ListenerSet<UInt32>()
        let registrar = Registrar()
        for device: UInt32 in [1, 2, 1, 2, 1] { sync(&set, [device], registrar) }
        XCTAssertEqual(registrar.live, [1: 1], "one listener, on the current input")
        XCTAssertEqual(set.watched, [1])
        let adds = registrar.added.count
        sync(&set, [1], registrar)
        XCTAssertEqual(registrar.added.count, adds, "an unchanged device list is left alone")
        sync(&set, [], registrar)
        XCTAssertTrue(registrar.live.isEmpty, "no input device, no listener")
    }

    func testCamerasThatLeaveLoseTheirListenerAndAFailedAddIsRetried() {
        var set = ListenerSet<UInt32>()
        let registrar = Registrar()
        registrar.refusing = [3]
        sync(&set, [1, 2, 3], registrar)
        XCTAssertEqual(set.watched, [1, 2], "a refused add is not counted as watched")
        registrar.refusing = []
        sync(&set, [2, 3], registrar)
        XCTAssertEqual(registrar.live, [2: 1, 3: 1])
        XCTAssertEqual(registrar.removed, [1])
    }
}
