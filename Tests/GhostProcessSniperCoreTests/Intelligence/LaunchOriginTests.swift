import XCTest
@testable import GhostProcessSniperCore

final class LaunchOriginTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private let fourHoursAgo = IntelligenceFixture.now.addingTimeInterval(-4 * 3_600)

    func testActiveEditorAppIsNotForgotten() throws {
        let code = Fixture.process(name: "Electron", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
                                   command: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
                                   megabytes: 900, cpu: 18, started: fourHoursAgo)
        var window = TrendWindow()
        let family = try XCTUnwrap(Fixture.scored([code], window: &window).first)

        XCTAssertNotEqual(family.forecast.state, .stale)
        XCTAssertFalse(family.score.components.contains { $0.title == "background dev process" })
        XCTAssertTrue(LaunchOrigin.isAppMainBinary(path: code.executablePath, name: code.name))
    }

    func testIdleDetachedDevServerIsStale() {
        let vite = Fixture.process(name: "node", command: "node node_modules/.bin/vite", megabytes: 300, cpu: 0, started: fourHoursAgo)
        let trend = Fixture.trend(megabytes: [300, 300, 300, 300, 300], cpu: [0, 1, 0, 0, 0])
        // Watched for two hours without doing any work.
        let idle = FamilyCPUActivity(buckets: [], lastActiveAt: nil, measuredSince: Fixture.now.addingTimeInterval(-7_200))
        let family = Fixture.family(vite, trend: trend, activity: idle)
        let forecast = FamilyRiskForecaster().forecast(family: family, settings: .smart, now: Fixture.now)
        XCTAssertEqual(forecast.state, .stale)

        let verdict = FamilyVerdict.synthesize(family: family.enriched(forecast: forecast),
                                               pattern: trend.resolvedPattern)
        XCTAssertEqual(verdict.headline, "Probably forgotten")
        XCTAssertTrue(verdict.detail.localizedCaseInsensitiveContains("running for 4 h"), verdict.detail)
        XCTAssertTrue(verdict.detail.localizedCaseInsensitiveContains("detached"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("no CPU use for 2 h"), verdict.detail)
    }

    func testBusyDetachedDevServerIsNotStale() {
        let vite = Fixture.process(name: "node", command: "node node_modules/.bin/vite", megabytes: 300, cpu: 1, started: fourHoursAgo)
        let trend = Fixture.trend(megabytes: [300, 300, 300, 300, 300], cpu: [0, 35, 0, 0, 1])
        let forecast = FamilyRiskForecaster().forecast(family: Fixture.family(vite, trend: trend), settings: .smart, now: Fixture.now)
        XCTAssertNotEqual(forecast.state, .stale)
    }

    func testHomebrewServiceIsNotStale() {
        let postgres = Fixture.process(name: "postgres", path: "/opt/homebrew/opt/postgresql@16/bin/postgres",
                                       command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16",
                                       megabytes: 700, cpu: 0, started: fourHoursAgo)
        XCTAssertTrue(LaunchOrigin.isLaunchdManaged(path: postgres.executablePath))
        let forecast = FamilyRiskForecaster().forecast(family: Fixture.family(postgres), settings: .smart, now: Fixture.now)
        XCTAssertNotEqual(forecast.state, .stale)
    }

    func testClassifiesLaunchOrigins() {
        XCTAssertTrue(LaunchOrigin.isAppMainBinary(path: "/Applications/Slack.app/Contents/MacOS/Slack", name: "Slack"))
        XCTAssertFalse(LaunchOrigin.isAppMainBinary(path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", name: "Slack Helper"))
        XCTAssertTrue(LaunchOrigin.isLaunchdManaged(path: "/usr/local/opt/redis/bin/redis-server"))
        XCTAssertTrue(LaunchOrigin.isLaunchdManaged(path: "/usr/libexec/trustd"))
        XCTAssertFalse(LaunchOrigin.isLaunchdManaged(path: "/usr/local/bin/node"))
        XCTAssertFalse(LaunchOrigin.isLaunchdManaged(path: "/opt/homebrew/opt/node/libexec/lib/node_modules/npm"))
    }
}
