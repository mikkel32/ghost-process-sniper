import XCTest
@testable import GhostProcessSniperCore

/// Siri holds the microphone open all day, waiting for "Hey Siri". That must not keep the tile
/// orange, or it can no longer say when a real app starts recording.
final class SentinelSensorTests: XCTestCase {
    private let siriPath = "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd"
    private let siri = PrivacySensorUser(pid: 101, name: "Siri (listening for \u{201C}Hey Siri\u{201D})", isPassive: true)
    private let zoom = PrivacySensorUser(pid: 202, name: "zoom.us")

    func testOnlyAppleSWakePhraseListenerIsPassive() {
        XCTAssertTrue(PrivacySensorReader.isPassiveClient(name: "corespeechd", path: siriPath))
        // The name is not enough: any program can be called corespeechd.
        for path in ["/tmp/corespeechd", "/Users/me/Library/corespeechd", "/private/tmp/x/corespeechd",
                     "/System/Volumes/Data/Users/me/corespeechd", "/usr/local/bin/corespeechd",
                     "/System/Library/PrivateFrameworks/CoreSpeech.framework/../../../../../tmp/corespeechd",
                     siriPath + "_system", "corespeechd", ""] {
            XCTAssertFalse(PrivacySensorReader.isPassiveClient(name: "corespeechd", path: path), path)
        }
        XCTAssertFalse(PrivacySensorReader.isPassiveClient(name: "corespeechd", path: nil), "a path that cannot be read is not vouched for")
        // And the path is not enough: the name has to be that daemon's.
        XCTAssertFalse(PrivacySensorReader.isPassiveClient(name: "zoom.us", path: siriPath))
        XCTAssertFalse(PrivacySensorReader.isPassiveClient(name: "corespeechd_system", path: siriPath))
        XCTAssertFalse(PrivacySensorReader.isPassiveClient(name: "Corespeechd", path: siriPath))
    }

    func testAMicrophoneOnlySiriHoldsIsNotWorthAttention() {
        let waiting = PrivacySensorState(microphoneUsers: [siri], microphoneActive: true, available: true)
        XCTAssertTrue(waiting.microphoneActive, "it is still in use, and the tile still says so")
        XCTAssertTrue(waiting.microphoneIsPassive)
        XCTAssertFalse(waiting.microphoneNeedsAttention)

        var recording = waiting
        recording.microphoneUsers = [siri, zoom]
        XCTAssertFalse(recording.microphoneIsPassive, "a real app joining Siri ends the calm")
        XCTAssertTrue(recording.microphoneNeedsAttention)
    }

    func testAMicrophoneNoOneOwnsNeedsAttentionAndAQuietOneDoesNot() {
        let unattributed = PrivacySensorState(microphoneUsers: [], microphoneActive: true, available: true)
        XCTAssertFalse(unattributed.microphoneIsPassive)
        XCTAssertTrue(unattributed.microphoneNeedsAttention, "macOS names nobody: that is not calm")
        let quiet = PrivacySensorState(available: true)
        XCTAssertFalse(quiet.microphoneNeedsAttention)
        XCTAssertFalse(quiet.microphoneIsPassive)
        // A stale user list never counts while the microphone is off.
        let idle = PrivacySensorState(microphoneUsers: [zoom], microphoneActive: false, available: true)
        XCTAssertFalse(idle.microphoneNeedsAttention)
    }

    func testTheCameraIsNotAffected() {
        let state = PrivacySensorState(microphoneUsers: [siri], microphoneActive: true, cameraActive: true,
                                       cameraDeviceNames: ["FaceTime HD Camera"], available: true)
        XCTAssertTrue(state.cameraActive)
        XCTAssertFalse(state.microphoneNeedsAttention)
    }

    func testPassiveIsPartOfWhoIsUsingTheMicrophone() {
        // The engine republishes when the read changes; a client turning passive or not is a change.
        XCTAssertNotEqual(PrivacySensorUser(pid: 101, name: "x"), PrivacySensorUser(pid: 101, name: "x", isPassive: true))
    }
}
