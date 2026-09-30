import XCTest
@testable import GhostProcessSniperCore

/// The Energy header's words are decided in Core so they can be tested; the
/// expected strings go through `EnergyFormat` so no test depends on the
/// machine's decimal separator.
final class EnergyHeadlineTests: XCTestCase {
    private func outlook(_ state: PowerState, charge: Double? = 76, draw: Double? = 26, rated: Double? = 65,
                         minutes: Double? = nil) -> BatteryOutlook {
        BatteryOutlook(
            chargePercent: charge, isDischarging: state == .onBattery, isCharging: state == .charging,
            drawWatts: draw, remainingWattHours: 50, minutesRemaining: minutes, healthPercent: 74, cycleCount: 100,
            adapterInputWatts: 39, powerState: state, adapterRatedWatts: state == .onBattery ? nil : rated)
    }

    private func report(_ battery: BatteryOutlook?, measured: Double = 0) -> EnergyReport {
        EnergyReport(generatedAt: Date(), perProcessEnergy: true, battery: battery, measuredWatts: measured,
                     lastHourWattHours: 0, consumers: [], blockers: [], findings: [], minuteWatts: [],
                     measuredProcessCount: 0, unmeasuredProcessCount: 0)
    }

    func testEachStateHasItsOwnTitle() {
        XCTAssertEqual(EnergyHeadline(report(outlook(.charging))).title, "Charging \u{00B7} 76%")
        XCTAssertEqual(EnergyHeadline(report(outlook(.pluggedIn))).title, "Plugged in, not charging \u{00B7} 76%")
        XCTAssertEqual(EnergyHeadline(report(outlook(.drainingOnPower))).title,
                       "Draining while plugged in \u{00B7} 76%")
        XCTAssertEqual(EnergyHeadline(report(outlook(.onBattery, minutes: 250))).title,
                       "About \(EnergyFormat.duration(250 * 60)) of battery left")
        XCTAssertEqual(EnergyHeadline(report(outlook(.onBattery))).title, "On battery \u{00B7} 76%")
        XCTAssertEqual(EnergyHeadline(report(nil)).title, "Energy use")
        XCTAssertEqual(EnergyHeadline(report(outlook(.pluggedIn, charge: nil, draw: 18))).title,
                       "Drawing \(EnergyFormat.watts(18))", "a desktop has no charge to show")
    }

    func testTheChargerChipIsTheRatingNeverTheLiveInput() {
        let headline = EnergyHeadline(report(outlook(.charging, rated: 65)))
        XCTAssertEqual(headline.chargerTag, "Charger \(EnergyFormat.watts(65))")
        XCTAssertFalse(headline.chargerTag?.contains(EnergyFormat.watts(39)) ?? true, "39 W is what it delivers now")
        XCTAssertNil(EnergyHeadline(report(outlook(.charging, rated: nil))).chargerTag, "no rating, no chip")
        XCTAssertNil(EnergyHeadline(report(outlook(.onBattery))).chargerTag)
    }

    func testTheDrawSentenceSaysWhenTheBatteryCoversTheRest() {
        let plain = EnergyHeadline(report(outlook(.charging, draw: 26)))
        XCTAssertEqual(plain.drawSentence, "Your Mac is drawing \(EnergyFormat.watts(26))")
        let short = EnergyHeadline(report(outlook(.drainingOnPower, draw: 94)))
        XCTAssertEqual(short.drawSentence,
                       "Your Mac is drawing \(EnergyFormat.watts(94)); the charger can\u{2019}t keep up, so the battery covers the rest")
        XCTAssertEqual(EnergyHeadline(report(outlook(.drainingOnPower, draw: nil))).drawSentence,
                       "The charger can\u{2019}t keep up, so the battery covers the rest")
        XCTAssertNil(EnergyHeadline(report(outlook(.charging, draw: nil))).drawSentence)
        XCTAssertNil(EnergyHeadline(report(nil)).drawSentence)
    }

    func testTheHeaderSetsTheAppsAgainstTheSameFiveMinutesOfDraw() {
        // The last minute spiked to 60 W; over the five minutes the apps were measured the Mac drew 20 W.
        var battery = outlook(.charging, draw: 60)
        battery.averageDrawWatts = 20
        let headline = EnergyHeadline(report(battery, measured: 3.4))
        XCTAssertEqual(headline.drawSentence, "Your Mac is drawing \(EnergyFormat.watts(20))")
        XCTAssertEqual(headline.attributionSentence, "apps and jobs account for \(EnergyFormat.watts(3.4)) of it (17%)")
        XCTAssertNil(EnergyHeadline(report(battery, measured: 25)).attributionSentence, "more than the whole Mac")
        XCTAssertNil(EnergyHeadline(report(nil, measured: 3.4)).attributionSentence, "no draw to compare with")
    }

    func testTheGlanceLineFollowsTheStateToo() {
        func line(_ state: PowerState) -> String? { EnergyGlance(report(outlook(state, draw: 26))).batteryLine }
        XCTAssertEqual(line(.charging), "Charging 76% \u{00B7} drawing 26 W")
        XCTAssertEqual(line(.pluggedIn), "Plugged in 76% \u{00B7} drawing 26 W")
        XCTAssertEqual(line(.drainingOnPower), "Plugged in 76% \u{00B7} battery draining \u{00B7} drawing 26 W")
    }

    /// The popover said "drawing 31 W" (the last ninety seconds) while the
    /// Energy page said 19 W (five minutes): one Mac, one moment, two numbers.
    func testThePopoverAndTheEnergyPageShowTheSameDraw() {
        var battery = outlook(.charging, draw: 31)
        battery.averageDrawWatts = 19
        let energy = report(battery)
        XCTAssertEqual(EnergyGlance(energy).drawWatts, 19)
        XCTAssertEqual(EnergyHeadline(energy).drawSentence, "Your Mac is drawing \(EnergyFormat.watts(19))")
        XCTAssertEqual(EnergyGlance(report(outlook(.charging, draw: 31))).drawWatts, 31, "until the mean exists, the recent draw")
    }
}
