import XCTest
@testable import GhostProcessSniperCore

final class ThresholdSettingsCodingTests: XCTestCase {
    func testUnreadSustainedSecondsStillRoundTripsUnderItsSavedKey() throws {
        let saved = #"{"memoryBytes": 1073741824, "cpuPercent": 80, "sustainedSeconds": 7}"#
        let decoded = try JSONDecoder().decode(ThresholdSettings.self, from: Data(saved.utf8))
        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["sustainedSeconds"] as? Double, 7)
        XCTAssertNil(object["legacySustainedSeconds"])
        XCTAssertEqual(try JSONDecoder().decode(ThresholdSettings.self, from: encoded), decoded)
    }

    func testEncodedKeysAreUnchanged() throws {
        let encoded = try JSONEncoder().encode(ThresholdSettings.smart)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "memoryBytes", "cpuPercent", "leakVelocityMegabytesPerMinute", "sustainedSeconds",
            "refreshInterval", "forceKillDelay", "radarMode", "groupFamilies", "performanceMode",
            "detectionMode", "sensitivity", "adaptivePerformance"
        ])
    }
}
