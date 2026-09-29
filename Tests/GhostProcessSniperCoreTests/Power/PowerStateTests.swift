import XCTest
@testable import GhostProcessSniperCore

/// The header's Charging / Plugged in / Draining states come from which way
/// current really flows, not from the IsCharging flag, and the charger chip
/// from the adapter's rating, not from what it delivers this second.
final class PowerStateTests: XCTestCase {
    private func plugged(
        charging: Bool = true, amperage: Double? = nil, load: Double? = nil, input: Double? = nil,
        rated: Double? = 65
    ) -> BatteryReading {
        BatteryReading(
            hasBattery: true, onExternalPower: true, isCharging: charging, chargePercent: 76,
            voltageMillivolts: 12_500, amperageMilliamps: amperage, systemLoadWatts: load,
            adapterInputWatts: input, adapterRatedWatts: rated, readAt: Date())
    }

    func testAChargerThatCannotKeepUpIsNotCharging() {
        // The screenshot's numbers: 94 W wanted, 65 W supplied, the flag still says charging.
        let reading = plugged(charging: true, amperage: -2_300, load: 94, input: 65)
        XCTAssertEqual(reading.netBatteryWatts ?? 0, -28.75, accuracy: 0.01)
        XCTAssertEqual(reading.powerState(after: nil), .drainingOnPower)
    }

    func testChargingMeansCurrentGoingIntoTheBattery() {
        XCTAssertEqual(plugged(charging: true, amperage: 2_540, load: 31, input: 39).powerState(after: nil), .charging)
        XCTAssertEqual(plugged(charging: false, amperage: 2_540, input: 39).powerState(after: nil), .charging,
                       "current into the battery is charging whatever the flag says")
    }

    func testAFlowInsideTheDeadBandIsPluggedInNotCharging() {
        // 20 mA at 12.5 V is a quarter of a watt: a full battery being held, not charged.
        XCTAssertEqual(plugged(charging: true, amperage: 20, input: 20).powerState(after: nil), .pluggedIn)
        XCTAssertEqual(plugged(charging: false, amperage: -30, input: 20).powerState(after: nil), .pluggedIn)
    }

    func testWithoutCurrentTheFlagDecides() {
        XCTAssertEqual(plugged(charging: true).powerState(after: nil), .charging)
        XCTAssertEqual(plugged(charging: false).powerState(after: nil), .pluggedIn)
    }

    func testStaleCurrentRightAfterPluggingInDoesNotClaimADrain() {
        // The telemetry still holds the on-battery reading for a few seconds, but the wall input is zero.
        let stale = plugged(charging: true, amperage: -2_300, load: 29, input: 0)
        XCTAssertEqual(stale.powerState(after: nil), .charging, "trust the flag over a flow the charger does not back")
        XCTAssertEqual(plugged(charging: false, amperage: -2_300, input: 0).powerState(after: nil), .pluggedIn)
    }

    func testAnUnknownRatingCannotContradictTheFlow() {
        XCTAssertEqual(plugged(charging: true, amperage: -2_300, input: 40, rated: nil).powerState(after: nil),
                       .drainingOnPower)
    }

    func testTheStateHoldsAtItsEdgeInsteadOfFlickering() {
        let drifting = plugged(charging: true, amperage: -64, input: 65)   // -0.8 W
        XCTAssertEqual(drifting.powerState(after: nil), .pluggedIn, "too small to start a drain")
        XCTAssertEqual(drifting.powerState(after: .drainingOnPower), .drainingOnPower, "but enough to keep one")
        let trickle = plugged(charging: true, amperage: 24, input: 20)     // +0.3 W
        XCTAssertEqual(trickle.powerState(after: .pluggedIn), .pluggedIn)
        XCTAssertEqual(trickle.powerState(after: .charging), .charging)
    }

    func testOnBatteryAndNoBattery() {
        var reading = plugged(amperage: -1_000)
        reading.onExternalPower = false
        XCTAssertEqual(reading.powerState(after: .charging), .onBattery)
        XCTAssertNil(BatteryReading.none.powerState(after: nil))
    }

    func testTheRatingComesFromTheAdapterDetailsAndOnlyWhenItIsSane() {
        XCTAssertEqual(IOKitBatterySource.adapterRating(["Watts": NSNumber(value: 65), "Name": "67W USB-C Power Adapter"]), 65)
        XCTAssertNil(IOKitBatterySource.adapterRating(nil))
        XCTAssertNil(IOKitBatterySource.adapterRating(["Name": "x"]))
        XCTAssertNil(IOKitBatterySource.adapterRating(["Watts": NSNumber(value: 0)]))
        XCTAssertNil(IOKitBatterySource.adapterRating(["Watts": NSNumber(value: -5)]))
    }

    func testOnlyPowerLeavingTheBatteryCountsAsDischarge() {
        // BatteryPower is signed: positive goes into the battery. A charging value left over
        // from before unplugging is not what the battery delivers.
        XCTAssertNil(IOKitBatterySource.dischargeWatts(batteryPowerMilliwatts: 8_061))
        XCTAssertNil(IOKitBatterySource.dischargeWatts(batteryPowerMilliwatts: 0))
        XCTAssertNil(IOKitBatterySource.dischargeWatts(batteryPowerMilliwatts: nil))
        XCTAssertEqual(IOKitBatterySource.dischargeWatts(batteryPowerMilliwatts: -27_700) ?? 0, 27.7, accuracy: 1e-9)
    }
}
