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
            "detectionMode", "sensitivity", "adaptivePerformance", "notifications"
        ])
    }

    /// Settings saved before the alert choices existed must load with every field intact and every alert on.
    func testSettingsSavedBeforeNotificationChoicesLoseNothing() throws {
        let saved = #"""
        {"memoryBytes": 2147483648, "cpuPercent": 55, "leakVelocityMegabytesPerMinute": 90, "sustainedSeconds": 7,
         "refreshInterval": 2, "forceKillDelay": 3, "radarMode": "heavy", "groupFamilies": false,
         "performanceMode": "batterySaver", "detectionMode": "custom", "sensitivity": "proactive",
         "adaptivePerformance": false}
        """#
        let decoded = try JSONDecoder().decode(ThresholdSettings.self, from: Data(saved.utf8))
        XCTAssertEqual(decoded.memoryBytes, 2_147_483_648)
        XCTAssertEqual(decoded.cpuPercent, 55)
        XCTAssertEqual(decoded.radarMode, .heavy)
        XCTAssertFalse(decoded.groupFamilies)
        XCTAssertEqual(decoded.performanceMode, .batterySaver)
        XCTAssertEqual(decoded.sensitivity, .proactive)
        XCTAssertEqual(decoded.notifications, NotificationPreferences())
        XCTAssertTrue(decoded.notifications.families && decoded.notifications.energy)
        XCTAssertEqual(decoded.notifications.security, .suspiciousAndDangerous)
    }

    func testChosenNotificationsRoundTrip() throws {
        var settings = ThresholdSettings.smart
        settings.notifications = NotificationPreferences(families: false, energy: false, security: .dangerousOnly)
        let decoded = try JSONDecoder().decode(ThresholdSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.notifications.security, .dangerousOnly)
    }

    /// One unreadable choice must never make the store fall back to the defaults for every setting.
    func testAnUnreadableNotificationChoiceNeverResetsTheRest() throws {
        let unknownLevel = #"{"memoryBytes": 2147483648, "cpuPercent": 55, "notifications": {"families": false, "security": "off"}}"#
        let decoded = try JSONDecoder().decode(ThresholdSettings.self, from: Data(unknownLevel.utf8))
        XCTAssertEqual(decoded.cpuPercent, 55)
        XCTAssertEqual(decoded.memoryBytes, 2_147_483_648)
        XCTAssertFalse(decoded.notifications.families, "the readable choice is kept")
        XCTAssertEqual(decoded.notifications.security, .suspiciousAndDangerous, "an unknown level means the default, not off")

        let garbage = #"{"cpuPercent": 55, "notifications": "loud"}"#
        let other = try JSONDecoder().decode(ThresholdSettings.self, from: Data(garbage.utf8))
        XCTAssertEqual(other.cpuPercent, 55)
        XCTAssertEqual(other.notifications, NotificationPreferences())
    }

    func testEveryAlertIsOnByDefaultAndSecurityCanOnlyNarrowToDangerous() {
        let defaults = NotificationPreferences()
        XCTAssertTrue(defaults.families)
        XCTAssertTrue(defaults.energy)
        XCTAssertEqual(defaults.security, .suspiciousAndDangerous)
        XCTAssertEqual(ThresholdSettings.smart.notifications, defaults)
        XCTAssertEqual(ThresholdSettings.aggressive.notifications, defaults)
        // There is no level that silences a dangerous finding.
        XCTAssertEqual(Set(SecurityAlertLevel.allCases.map(\.rawValue)), ["suspiciousAndDangerous", "dangerousOnly"])
    }
}
