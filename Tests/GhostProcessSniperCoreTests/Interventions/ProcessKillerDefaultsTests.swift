import XCTest
@testable import GhostProcessSniperCore

/// The app builds its killer with defaults, so the defaults are the real
/// stop path: the native snapshot provider, not a sampler-backed lookup.
final class ProcessKillerDefaultsTests: XCTestCase {
    func testDefaultKillerUsesTheNativeSnapshotProvider() {
        XCTAssertTrue(ProcessKiller().snapshotProvider is NativeKillSnapshotProvider)
    }
}
