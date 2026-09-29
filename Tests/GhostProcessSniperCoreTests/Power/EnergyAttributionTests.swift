import XCTest
@testable import GhostProcessSniperCore

final class EnergyAttributionTests: XCTestCase {
    func testTheShareIsWhatAppsAndJobsAccountForOutOfTheMacsDraw() {
        let attribution = EnergyAttribution(mac: 20, measured: 3.4, perProcessEnergy: true)
        XCTAssertEqual(attribution?.sharePercent, 17)
        XCTAssertEqual(attribution?.restWatts ?? 0, 16.6, accuracy: 1e-9)
        XCTAssertEqual(attribution?.sentence, "apps and jobs account for \(EnergyFormat.watts(3.4)) of it (17%)")
    }

    func testAComparisonThatCannotBeRightSaysNothing() {
        XCTAssertNil(EnergyAttribution(mac: 20, measured: 25, perProcessEnergy: true), "more than the whole Mac")
        XCTAssertNil(EnergyAttribution(mac: nil, measured: 3, perProcessEnergy: true))
        XCTAssertNil(EnergyAttribution(mac: 20, measured: 0, perProcessEnergy: true))
        XCTAssertNil(EnergyAttribution(mac: 0, measured: 0, perProcessEnergy: true))
        XCTAssertNil(EnergyAttribution(mac: 20, measured: 3, perProcessEnergy: false), "this Mac does not measure per process")
    }

    func testTheShareStaysBetweenOneAndNinetyNine() {
        XCTAssertEqual(EnergyAttribution(mac: 20, measured: 0.05, perProcessEnergy: true)?.sharePercent, 1)
        XCTAssertEqual(EnergyAttribution(mac: 20, measured: 19.95, perProcessEnergy: true)?.sharePercent, 99)
    }

    func testThePercentSignIsWrittenOnceWhateverTheLocale() {
        let sentence = EnergyAttribution(mac: 26, measured: 3.3, perProcessEnergy: true)?.sentence ?? ""
        XCTAssertEqual(sentence.filter { $0 == "%" }.count, 1)
        XCTAssertTrue(sentence.hasSuffix("(13%)"))
        XCTAssertTrue(sentence.contains(EnergyFormat.watts(3.3)), "written with the reader's decimal separator")
    }
}
