import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The welcome opens once, for someone who has never run Ghost. Anyone who
/// already has a radar store (every 2.x user), anyone who has seen it, and
/// anyone who launched with a window in mind never get it.
final class WelcomePolicyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("radar-welcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var storeURL: URL {
        folder.appendingPathComponent("Ghost Process Sniper", isDirectory: true).appendingPathComponent("Radar.sqlite")
    }

    // MARK: Who is welcomed

    func testFirstEverLaunchWelcomes() {
        XCTAssertTrue(WelcomePolicy.shouldWelcome(lastSeenVersion: 0, isFirstEverLaunch: true, launchArguments: []))
    }

    func testAnUpgradeIsNotWelcomedAsANewcomer() {
        XCTAssertFalse(WelcomePolicy.shouldWelcome(lastSeenVersion: 0, isFirstEverLaunch: false, launchArguments: []))
    }

    func testASeenWelcomeIsNotRepeated() {
        let seen = WelcomePolicy.currentVersion
        XCTAssertFalse(WelcomePolicy.shouldWelcome(lastSeenVersion: seen, isFirstEverLaunch: true, launchArguments: []))
        XCTAssertFalse(WelcomePolicy.shouldWelcome(lastSeenVersion: seen + 1, isFirstEverLaunch: true, launchArguments: []),
                       "a newer build's record must hold when an older build is opened")
    }

    func testExplicitLaunchRequestsWinOverTheWelcome() {
        for arguments in [["Ghost", "--console"], ["Ghost", "--section", "security"], ["Ghost", "--section"]] {
            XCTAssertFalse(WelcomePolicy.shouldWelcome(lastSeenVersion: 0, isFirstEverLaunch: true, launchArguments: arguments),
                           "\(arguments)")
        }
        XCTAssertTrue(WelcomePolicy.shouldWelcome(lastSeenVersion: 0, isFirstEverLaunch: true,
                                                  launchArguments: ["/Applications/Ghost Process Sniper.app/Contents/MacOS/GhostProcessSniper", "-NSDocumentRevisionsDebugMode", "YES"]),
                      "system launch arguments are not a request for a window")
    }

    // MARK: First-ever detection

    func testAMissingStoreFolderIsAFirstLaunch() {
        XCTAssertTrue(WelcomePolicy.isFirstEverLaunch(storeURL: storeURL))
    }

    func testAnExistingStoreFolderIsNotAFirstLaunch() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertFalse(WelcomePolicy.isFirstEverLaunch(storeURL: storeURL))
    }

    /// The app decides before its first refresh, but after the monitor (and so
    /// the store object) exists. That only works while the store creates its
    /// folder when it first opens, not when it is made, and this is the folder
    /// the check reads.
    func testTheFolderTheStoreCreatesOnFirstUseIsTheOneTheCheckReads() async throws {
        XCTAssertTrue(WelcomePolicy.isFirstEverLaunch(storeURL: storeURL))
        let store = RadarStore(url: storeURL)
        XCTAssertTrue(WelcomePolicy.isFirstEverLaunch(storeURL: storeURL), "making the store must not make the next launch look old")
        _ = try await store.loadSettings(defaults: .smart)
        XCTAssertFalse(WelcomePolicy.isFirstEverLaunch(storeURL: storeURL), "a store in use means an existing user")
        await store.close()
    }

    func testTheCheckLooksWhereTheAppKeepsItsStore() {
        let fileManager = RecordingFileManager()
        _ = WelcomePolicy.isFirstEverLaunch(fileManager: fileManager)
        XCTAssertEqual(fileManager.checkedPaths, [RadarStore.defaultURL().deletingLastPathComponent().path])
    }

    // MARK: Launch at login

    func testLoginIsOfferedOnlyFromAnApplicationsFolder() {
        let home = URL(fileURLWithPath: "/Users/sam", isDirectory: true)
        func offered(_ path: String) -> Bool {
            WelcomePolicy.offersLaunchAtLogin(bundleURL: URL(fileURLWithPath: path, isDirectory: true), homeDirectory: home)
        }
        XCTAssertTrue(offered("/Applications/Ghost Process Sniper.app"))
        XCTAssertTrue(offered("/Applications/Utilities/Ghost Process Sniper.app"))
        XCTAssertTrue(offered("/Users/sam/Applications/Ghost Process Sniper.app"))

        // A disk image, a quarantined copy that macOS runs from a random
        // read-only mount, and ordinary folders all lose the login item.
        XCTAssertFalse(offered("/Volumes/Ghost Process Sniper/Ghost Process Sniper.app"))
        XCTAssertFalse(offered("/private/var/folders/x1/abc/T/AppTranslocation/6A1F/d/Ghost Process Sniper.app"))
        XCTAssertFalse(offered("/Users/sam/Downloads/Ghost Process Sniper.app"))
        XCTAssertFalse(offered("/Users/sam/Desktop/Ghost Process Sniper.app"))
        XCTAssertFalse(offered("/Users/sam/projects/ghost/dist/Ghost Process Sniper.app"))
        XCTAssertFalse(offered("/Users/kim/Applications/Ghost Process Sniper.app"), "another user's folder is not this user's")
        XCTAssertFalse(offered("/ApplicationsOld/Ghost Process Sniper.app"), "only the folder itself counts, not a name that starts like it")
        XCTAssertFalse(offered("/Applications"), "the folder is not an app inside it")
    }

    func testLoginIsOfferedWhateverTheCaseOfTheFolder() {
        let home = URL(fileURLWithPath: "/Users/sam", isDirectory: true)
        XCTAssertTrue(WelcomePolicy.offersLaunchAtLogin(bundleURL: URL(fileURLWithPath: "/applications/Ghost Process Sniper.app"), homeDirectory: home),
                      "the default volume ignores case, so a path typed in lowercase still starts from Applications")
    }
}

/// Answers "yes" and remembers what it was asked, so a test can see which
/// folder a check reads without touching the real one.
private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var checkedPaths: [String] {
        lock.withLock { paths }
    }

    override func fileExists(atPath path: String) -> Bool {
        lock.withLock { paths.append(path) }
        return true
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        lock.withLock { paths.append(path) }
        isDirectory?.pointee = true
        return true
    }
}
