import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class LaunchdJobResolverTests: XCTestCase {
    private var folder: LaunchAgentsFolder!

    override func setUp() {
        folder = LaunchAgentsFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    private let listing = """
    PID\tStatus\tLabel
    -\t0\tcom.apple.SafariHistoryServiceAgent
    812\t0\thomebrew.mxcl.postgresql@16
    913\t-9\tapplication.com.apple.Safari.1234.5678
    -\t78\thomebrew.mxcl.redis
    1044\t0\tcom.example.sync
    """

    func testParsesLaunchctlList() {
        let entries = LaunchdJobResolver.parseList(listing)

        XCTAssertEqual(entries.map(\.label), [
            "com.apple.SafariHistoryServiceAgent", "homebrew.mxcl.postgresql@16", "homebrew.mxcl.redis", "com.example.sync"
        ], "the header and apps started by LaunchServices are skipped")
        XCTAssertEqual(entries.map(\.pid), [nil, 812, nil, 1044])
    }

    func testFindsTheHomebrewServiceBehindAPID() async {
        let plist = folder.write(label: "homebrew.mxcl.postgresql@16", program: ["/opt/homebrew/opt/postgresql@16/bin/postgres"],
                                 keepAlive: true)
        let launchctl = FakeLaunchctl(list: listing)

        let job = await resolver(launchctl).job(forPID: 812, executablePath: "/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres")

        XCTAssertEqual(job?.label, "homebrew.mxcl.postgresql@16")
        XCTAssertEqual(job?.pid, 812)
        XCTAssertEqual(job?.keepAlive, true)
        XCTAssertEqual(job?.plistPath, plist)
        XCTAssertEqual(job?.homebrewFormula, "postgresql@16")
        XCTAssertEqual(job?.domainTarget, "gui/501/homebrew.mxcl.postgresql@16")
        XCTAssertEqual(job?.stopCommand, "brew services stop postgresql@16")
        XCTAssertEqual(job?.keepStoppedCommand, "brew services stop postgresql@16")
        XCTAssertEqual(job?.undoCommand, "brew services start postgresql@16")
        XCTAssertEqual(launchctl.invocations, [["list"]])
    }

    func testPlainAgentsGetLaunchctlCommands() async {
        let plist = folder.write(label: "com.example.sync", program: ["/usr/local/bin/sync-agent"], keepAlive: true,
                                 file: "sync.plist")

        let job = await resolver(FakeLaunchctl(list: listing)).job(forPID: 1044, executablePath: "/usr/local/bin/sync-agent")

        XCTAssertEqual(job?.plistPath, plist, "the plist is found by label, whatever its file name")
        XCTAssertNil(job?.homebrewFormula)
        XCTAssertEqual(job?.stopCommand, "launchctl bootout gui/501/com.example.sync")
        XCTAssertEqual(job?.keepStoppedCommand, "launchctl disable gui/501/com.example.sync")
        XCTAssertEqual(job?.undoCommand, "launchctl enable gui/501/com.example.sync && launchctl bootstrap gui/501 \(plist)")
    }

    func testAListedJobWithoutAPlistIsNotKeptAlive() async {
        let job = await resolver(FakeLaunchctl(list: listing)).job(forPID: 1044, executablePath: "/usr/local/bin/sync-agent")
        XCTAssertEqual(job?.label, "com.example.sync")
        XCTAssertEqual(job?.keepAlive, false)
        XCTAssertNil(job?.plistPath)
    }

    func testAPIDLaunchctlDoesNotListIsNotAJob() async {
        let postgres = folder.linkedExecutable(named: "postgres")
        folder.write(label: "homebrew.mxcl.postgresql@16", program: [postgres.link], keepAlive: true)

        let job = await resolver(FakeLaunchctl(list: listing)).job(forPID: 4242, executablePath: postgres.real)

        XCTAssertNil(job, "a second postgres run by hand is not the service")
    }

    func testFallsBackToTheProgramPathWhenLaunchctlCannotAnswer() async {
        let postgres = folder.linkedExecutable(named: "postgres")
        folder.write(label: "homebrew.mxcl.postgresql@16", program: [postgres.link], keepAlive: true)

        let job = await resolver(FakeLaunchctl(listStatus: LaunchdJobResolver.timedOutStatus))
            .job(forPID: 812, executablePath: postgres.real)

        XCTAssertEqual(job?.label, "homebrew.mxcl.postgresql@16")
        XCTAssertEqual(job?.keepAlive, true)
        XCTAssertNil(job?.pid, "a path match is advice, never a bootout target")
    }

    func testAnswersAreRememberedPerProcessIdentity() async {
        let launchctl = FakeLaunchctl(list: listing)
        let resolver = resolver(launchctl)
        let identity = ProcessIdentity(pid: 812, startTimeSeconds: 1_000, startTimeMicroseconds: 0)

        let first = await resolver.job(for: identity, executablePath: "")
        let again = await resolver.job(for: identity, executablePath: "")
        _ = await resolver.job(for: ProcessIdentity(pid: 812, startTimeSeconds: 2_000, startTimeMicroseconds: 0), executablePath: "")

        XCTAssertEqual(first, again)
        XCTAssertEqual(launchctl.invocations.count, 2, "a new process with the same PID is asked about again")
    }

    func testUnansweredLookupsAreNotRemembered() async {
        let launchctl = FakeLaunchctl(listStatus: LaunchdJobResolver.timedOutStatus)
        let resolver = resolver(launchctl)
        let identity = ProcessIdentity(pid: 812, startTimeSeconds: 1_000, startTimeMicroseconds: 0)

        _ = await resolver.job(for: identity, executablePath: "")
        _ = await resolver.job(for: identity, executablePath: "")

        XCTAssertEqual(launchctl.invocations.count, 2)
    }

    func testBootoutIssuesExactlyTheBootoutCommand() async {
        let launchctl = FakeLaunchctl()
        let bootout = await resolver(launchctl).bootout(postgresJob, keepOff: false)

        XCTAssertEqual(launchctl.invocations, [["bootout", "gui/501/homebrew.mxcl.postgresql@16"]])
        XCTAssertTrue(bootout.accepted)
        XCTAssertFalse(bootout.disabled)
    }

    func testKeepOffAlsoDisablesTheJob() async {
        let launchctl = FakeLaunchctl()
        let bootout = await resolver(launchctl).bootout(postgresJob, keepOff: true)

        XCTAssertEqual(launchctl.invocations, [
            ["bootout", "gui/501/homebrew.mxcl.postgresql@16"],
            ["disable", "gui/501/homebrew.mxcl.postgresql@16"]
        ])
        XCTAssertTrue(bootout.disabled)
    }

    func testRefusedBootoutIsNotAcceptedAndDisablesNothing() async {
        let launchctl = FakeLaunchctl(bootoutStatus: 5)
        let bootout = await resolver(launchctl).bootout(postgresJob, keepOff: true)

        XCTAssertFalse(bootout.accepted)
        XCTAssertEqual(bootout.status, 5)
        XCTAssertEqual(launchctl.invocations.count, 1)
    }

    func testTimedOutBootoutStillReachedLaunchd() async {
        let bootout = await resolver(FakeLaunchctl(bootoutStatus: LaunchdJobResolver.timedOutStatus)).bootout(postgresJob, keepOff: false)
        XCTAssertTrue(bootout.accepted)
    }

    // MARK: - Fixtures

    private var postgresJob: LaunchdJob {
        LaunchdJob(label: "homebrew.mxcl.postgresql@16", pid: 812, domain: "gui/501", plistPath: nil, keepAlive: true)
    }

    private func resolver(_ launchctl: FakeLaunchctl) -> LaunchdJobResolver {
        LaunchdJobResolver(launchctl: launchctl, index: folder.index(), userID: 501)
    }
}
