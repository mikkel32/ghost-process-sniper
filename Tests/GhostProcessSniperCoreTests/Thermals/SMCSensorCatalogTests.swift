import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class SMCSensorCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_300_000)

    func testChipGenerationParsesWholeNumbers() {
        let cases: [(String, Int?)] = [
            ("Apple M1 Pro", 1), ("Apple M2 Max", 2), ("Apple M3", 3), ("Apple M4 Max", 4), ("Apple M5", 5),
            ("Apple M10", 10), ("Apple M1X", nil), ("Apple M", nil),
            ("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", nil), ("", nil)
        ]
        for (brand, expected) in cases {
            XCTAssertEqual(SMCSensorCatalog.generation(fromBrand: brand), expected, brand)
        }
    }

    func testEachChipGetsItsOwnTable() throws {
        let m1 = try XCTUnwrap(SMCSensorCatalog.mapping(forBrand: "Apple M1 Max"))
        XCTAssertEqual(m1.source, .verified)
        XCTAssertTrue(m1.cpuKeys.contains("Tp0T"))
        XCTAssertEqual(SMCSensorCatalog.mapping(forBrand: "Apple M2")?.gpuKeys, ["Tg0f", "Tg0j"])
        let m3 = try XCTUnwrap(SMCSensorCatalog.mapping(forBrand: "Apple M3 Pro"))
        XCTAssertEqual(m3.source, .catalog)
        XCTAssertEqual(m3.cpuKeys.count, 16)
        XCTAssertEqual(m3.gpuKeys.first, "Tf14")
        let m4 = try XCTUnwrap(SMCSensorCatalog.mapping(forBrand: "Apple M4 Max"))
        XCTAssertEqual(m4.source, .catalog)
        XCTAssertEqual(m4.cpuKeys.count, 12)
        XCTAssertEqual(m4.gpuKeys.count, 10)
        XCTAssertEqual(SMCSensorCatalog.mapping(forBrand: "Intel(R) Core(TM) i7")?.cpuKeys, ["TC0D", "TC0P"])
        XCTAssertNil(SMCSensorCatalog.mapping(forBrand: "Apple M5"), "M5 has no table; it is discovered")
        XCTAssertNil(SMCSensorCatalog.mapping(forBrand: "Apple M10"), "M10 must not reuse the M1 table")
        XCTAssertNil(SMCSensorCatalog.mapping(forBrand: "Unknown CPU"))
    }

    func testCatalogChipReadsItsKeysAndReportsTheSource() async {
        let smc = FakeSMC(values: ["Te05": 61, "Tp01": 74, "Tp05": 70, "Tg0G": 52])
        let sampler = ThermalSampler(brand: "Apple M4 Pro", makeTransport: { smc })
        let snapshot = await sampler.sample(now: now)
        XCTAssertEqual(snapshot.cpuCelsius, 74)
        XCTAssertEqual(snapshot.cpuSensorKey, "Tp01")
        XCTAssertEqual(snapshot.cpuSeriesID, "cpu:Te05,Tp01,Tp05")
        XCTAssertEqual(snapshot.gpuSeriesID, "gpu:Tg0G")
        XCTAssertEqual(snapshot.mappingSource, .catalog)
        XCTAssertEqual(snapshot.mappingNote, "Sensor map from the chip catalog; not yet verified on this model")
        XCTAssertNil(snapshot.unavailableReason)
        XCTAssertEqual(smc.calls(command: 8), 0, "A catalog chip never enumerates keys")
    }

    func testDiscoveryKeepsPlausibleDieSensorsOnly() async throws {
        let smc = FakeSMC(values: ["Tp01": 48, "Te05": 51, "Tg0G": 40, "Tf04": 55, "Tp09": 150, "Tp0X": 5,
                                   "TA0P": 30],
                          types: ["Tp0Y": ("ui8 ", 1), "TC0P": ("sp78", 2)],
                          extraKeys: ["FNum", "Tp0Y", "TC0P"])
        let sampler = ThermalSampler(brand: "Apple M5 Pro", makeTransport: { smc })
        let snapshot = await sampler.sample(now: now)
        XCTAssertEqual(snapshot.mappingSource, .discovered)
        XCTAssertEqual(Set(snapshot.sensorKeys), ["Tp01", "Te05", "Tg0G"])
        XCTAssertEqual(snapshot.cpuCelsius, 51)
        XCTAssertEqual(snapshot.gpuCelsius, 40)
        let enumerations = smc.calls(command: 8)
        _ = await sampler.sample(now: now.addingTimeInterval(5))
        XCTAssertEqual(smc.calls(command: 8), enumerations, "Discovery runs once")
    }

    func testTfOnlyLayoutLeavesTheCPUUnmappedInsteadOfGuessing() async {
        let smc = FakeSMC(values: ["Tf04": 60, "Tf09": 62, "Tf14": 45, "Tg0G": 44])
        let sampler = ThermalSampler(brand: "Apple M5", makeTransport: { smc })
        let snapshot = await sampler.sample(now: now)
        XCTAssertNil(snapshot.cpuCelsius)
        XCTAssertEqual(snapshot.gpuCelsius, 44)
        XCTAssertEqual(snapshot.sensorKeys, ["Tg0G"])
    }

    func testDiscoveryIsBoundedByTheIndexCap() async {
        let smc = FakeSMC(values: [:], reportedKeyCount: 1_000_000)
        let sampler = ThermalSampler(brand: "Apple M6", makeTransport: { smc })
        let snapshot = await sampler.sample(now: now)
        XCTAssertLessThanOrEqual(smc.calls(command: 8), SMCKeyReader.maximumDiscoveryIndices)
        XCTAssertNil(snapshot.mappingSource)
        XCTAssertEqual(snapshot.unavailableReason, "No readable temperature sensors were found on this Mac")
    }

    func testMissingKeysAreNotAskedForAgain() async {
        let smc = FakeSMC(values: ["Tp01": 70])
        let sampler = ThermalSampler(brand: "Apple M1", makeTransport: { smc })
        _ = await sampler.sample(now: now)
        _ = await sampler.sample(now: now.addingTimeInterval(4))
        XCTAssertEqual(smc.calls(command: 9, key: "Tp09"), 1, "Key-not-found is cached")
        XCTAssertEqual(smc.calls(command: 9, key: "Tp01"), 1, "Metadata is cached")
        XCTAssertEqual(smc.calls(command: 5, key: "Tp01"), 2)
    }

    // MARK: Fans (read-only)

    private func fanSnapshot(_ smc: FakeSMC, brand: String = "Apple M1 Pro", at offset: TimeInterval = 0) async -> ThermalSnapshot {
        await ThermalSampler(brand: brand, makeTransport: { smc }).sample(now: now.addingTimeInterval(offset))
    }

    func testFanSpeedIsReadNextToTheTemperatures() async {
        let smc = FakeSMC(values: ["Tp01": 70, "F0Ac": 2400, "F0Mx": 5800], types: ["FNum": ("ui8 ", 1)])
        let snapshot = await fanSnapshot(smc)
        XCTAssertEqual(snapshot.fans, [ThermalFan(rpm: 2400, maximumRPM: 5800)])
        XCTAssertEqual(snapshot.cpuCelsius, 70, "Fans never disturb the temperature reading")
        XCTAssertEqual(snapshot.fans.first?.fraction ?? 0, 2400.0 / 5800.0, accuracy: 1e-9)
    }

    func testFanSummaryIsWrittenInTheReadersLocale() {
        let fans = [ThermalFan(rpm: 2340, maximumRPM: 5700)]
        XCTAssertEqual(ThermalFan.summary(fans, locale: Locale(identifier: "en_US")), "Fans 2,340 rpm (41% of max)")
        XCTAssertEqual(ThermalFan.summary(fans, locale: Locale(identifier: "da_DK")), "Fans 2.340 rpm (41% of max)")
        XCTAssertEqual(ThermalFan.summary([ThermalFan(rpm: 2340, maximumRPM: nil)], locale: Locale(identifier: "en_US")),
                       "Fans 2,340 rpm", "No maximum, no percentage")
        XCTAssertNil(ThermalFan.summary([]))
    }

    func testFansBelowAHundredRPMAreIdle() {
        XCTAssertEqual(ThermalFan.summary([ThermalFan(rpm: 0, maximumRPM: 5800)]), "Fans idle")
        XCTAssertEqual(ThermalFan.summary([ThermalFan(rpm: 99, maximumRPM: 5800)]), "Fans idle")
        XCTAssertNotEqual(ThermalFan.summary([ThermalFan(rpm: 100, maximumRPM: 5800)]), "Fans idle")
        XCTAssertEqual(ThermalFan.summary([ThermalFan(rpm: 0, maximumRPM: nil), ThermalFan(rpm: 40, maximumRPM: nil)]),
                       "Fans idle", "Idle only when every fan is")
    }

    func testSeveralFansReportTheBusiestOne() async {
        let smc = FakeSMC(values: ["Tp01": 70, "F0Ac": 1200, "F0Mx": 6000, "F1Ac": 3000, "F1Mx": 6000],
                          types: ["FNum": ("ui8 ", 1)], bytes: ["FNum": [2]])
        let snapshot = await fanSnapshot(smc)
        XCTAssertEqual(snapshot.fans.map(\.rpm), [1200, 3000])
        XCTAssertEqual(ThermalFan.summary(snapshot.fans, locale: Locale(identifier: "en_US")), "Fans up to 3,000 rpm (50% of max)")
    }

    func testTheFractionStaysWithinZeroAndOne() {
        XCTAssertEqual(ThermalFan(rpm: 6100, maximumRPM: 6000).fraction, 1, "A fan may overshoot its listed maximum")
        XCTAssertNil(ThermalFan(rpm: 3000, maximumRPM: nil).fraction)
        XCTAssertNil(ThermalFan(rpm: 3000, maximumRPM: 0).fraction, "Never divide by a zero maximum")
    }

    func testAMacWithoutFansShowsNothingAndDoesNotKeepAsking() async {
        let smc = FakeSMC(values: ["Tp01": 70])
        let sampler = ThermalSampler(brand: "Apple M1", makeTransport: { smc })
        let first = await sampler.sample(now: now)
        let second = await sampler.sample(now: now.addingTimeInterval(4))
        XCTAssertEqual(first.fans, [])
        XCTAssertEqual(second.fans, [])
        XCTAssertEqual(second.cpuCelsius, 70)
        XCTAssertNil(second.fanText(at: now.addingTimeInterval(4)))
        XCTAssertEqual(smc.calls(command: 9, key: "FNum"), 1, "Key-not-found is cached")
        XCTAssertEqual(smc.calls(command: 5, key: "FNum"), 0)
        XCTAssertEqual(smc.calls(command: 9, key: "F0Ac"), 0, "Without a fan count there is nothing to read")
    }

    func testAFanCountOfZeroReadsNoFanKeys() async {
        let smc = FakeSMC(values: ["Tp01": 70, "F0Ac": 2400], types: ["FNum": ("ui8 ", 1)], bytes: ["FNum": [0]])
        let snapshot = await fanSnapshot(smc)
        XCTAssertEqual(snapshot.fans, [])
        XCTAssertEqual(smc.calls(command: 5, key: "F0Ac"), 0)
    }

    func testImplausibleFanReadingsAreDropped() async {
        for bad: Float in [65535, -20, .nan, .infinity] {
            let smc = FakeSMC(values: ["Tp01": 70, "F0Ac": bad, "F0Mx": 5800], types: ["FNum": ("ui8 ", 1)])
            let snapshot = await fanSnapshot(smc)
            XCTAssertEqual(snapshot.fans, [], "\(bad)")
        }
        let onlyOneBad = FakeSMC(values: ["Tp01": 70, "F0Ac": 0, "F1Ac": 65535], types: ["FNum": ("ui8 ", 1)], bytes: ["FNum": [2]])
        let snapshot = await fanSnapshot(onlyOneBad)
        XCTAssertEqual(snapshot.fans, [], "A fan that cannot be trusted must not let the others say idle")
    }

    func testAnImplausibleMaximumLeavesTheSpeedWithoutAPercentage() async {
        let smc = FakeSMC(values: ["Tp01": 70, "F0Ac": 2400, "F0Mx": 0], types: ["FNum": ("ui8 ", 1)])
        let snapshot = await fanSnapshot(smc)
        XCTAssertEqual(snapshot.fans, [ThermalFan(rpm: 2400, maximumRPM: nil)])
    }

    func testTheMaximumIsReadOnceButTheSpeedEverySample() async {
        let smc = FakeSMC(values: ["Tp01": 70, "F0Ac": 2400, "F0Mx": 5800], types: ["FNum": ("ui8 ", 1)])
        let sampler = ThermalSampler(brand: "Apple M1 Pro", makeTransport: { smc })
        _ = await sampler.sample(now: now)
        let second = await sampler.sample(now: now.addingTimeInterval(4))
        XCTAssertEqual(second.fans, [ThermalFan(rpm: 2400, maximumRPM: 5800)])
        XCTAssertEqual(smc.calls(command: 5, key: "F0Mx"), 1, "The maximum never changes")
        XCTAssertEqual(smc.calls(command: 5, key: "F0Ac"), 2)
        XCTAssertEqual(smc.calls(command: 5, key: "FNum"), 1, "The fan count never changes")
        XCTAssertEqual(smc.calls(command: 9, key: "F0Ac"), 1, "Metadata is cached")
    }

    func testFansAreReadEvenWhenNoTemperatureSensorIsMapped() async {
        let smc = FakeSMC(values: ["F0Ac": 1800, "F0Mx": 5000], types: ["FNum": ("ui8 ", 1)], extraKeys: ["FNum"])
        let snapshot = await fanSnapshot(smc, brand: "Apple M6")
        XCTAssertEqual(snapshot.sensorCount, 0)
        XCTAssertNotNil(snapshot.unavailableReason)
        XCTAssertEqual(snapshot.fans, [ThermalFan(rpm: 1800, maximumRPM: 5000)])
    }

    func testOlderIntelMacsReportFansAsFixedPointNumbers() async {
        // fpe2 is unsigned 14.2, big-endian: 0x0960 = 2400 quarter-rpm steps = 600 rpm.
        let smc = FakeSMC(values: ["TC0D": 60],
                          types: ["FNum": ("ui8 ", 1), "F0Ac": ("fpe2", 2), "F0Mx": ("fpe2", 2)],
                          bytes: ["F0Ac": [0x09, 0x60], "F0Mx": [0x1B, 0x58]])
        let snapshot = await fanSnapshot(smc, brand: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz")
        XCTAssertEqual(snapshot.cpuCelsius, 60)
        XCTAssertEqual(snapshot.fans, [ThermalFan(rpm: 600, maximumRPM: 1750)])
    }

    func testNumberCodecDecodesTheThreeFanEncodings() {
        XCTAssertEqual(SMCTemperatureCodec.decodeNumber(type: "fpe2", bytes: [0x09, 0x60]), 600)
        XCTAssertEqual(SMCTemperatureCodec.decodeNumber(type: "fpe2", bytes: [0x00, 0x01]), 0.25, "Quarter steps survive")
        XCTAssertEqual(SMCTemperatureCodec.decodeNumber(type: "fpe2", bytes: [0xFF, 0xFF]), 16383.75)
        XCTAssertEqual(SMCTemperatureCodec.decodeNumber(type: "ui8 ", bytes: [3]), 3)
        let bits = Float(2400).bitPattern
        let littleEndian = (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        XCTAssertEqual(SMCTemperatureCodec.decodeNumber(type: "flt ", bytes: littleEndian), 2400)
        XCTAssertNil(SMCTemperatureCodec.decodeNumber(type: "flt ", bytes: [0, 0, 0xC0, 0x7F]), "NaN is not a number")
        XCTAssertNil(SMCTemperatureCodec.decodeNumber(type: "fpe2", bytes: [0x09]), "Short data")
        XCTAssertNil(SMCTemperatureCodec.decodeNumber(type: "ui8 ", bytes: [1, 2]))
        XCTAssertNil(SMCTemperatureCodec.decodeNumber(type: "sp78", bytes: [0x18, 0x00]), "Temperatures keep their own decoder")
        XCTAssertEqual(SMCTemperatureCodec.decode(type: "sp78", bytes: [0x18, 0x00]), 24)
    }

    func testFanTextExpiresWithTheTemperatures() async {
        let smc = FakeSMC(values: ["Tp01": 70, "F0Ac": 0, "F0Mx": 5800], types: ["FNum": ("ui8 ", 1)])
        let snapshot = await fanSnapshot(smc)
        XCTAssertEqual(snapshot.fanText(at: now.addingTimeInterval(15)), "Fans idle")
        XCTAssertNil(snapshot.fanText(at: now.addingTimeInterval(16)), "No stale rpm beside an Unavailable temperature")
        XCTAssertNil(snapshot.fanText(at: now.addingTimeInterval(-1)), "A reading from the future is not current")
        XCTAssertEqual(snapshot.temperatureText(snapshot.cpuCelsius, at: now.addingTimeInterval(16)), "Unavailable")
        XCTAssertNil(ThermalSnapshot.unknown.fanText(at: now))
    }

    func testFanReadsUseOnlyTheReadCommands() async {
        let smc = FakeSMC(values: ["Tp01": 70, "F0Ac": 2400, "F0Mx": 5800], types: ["FNum": ("ui8 ", 1)])
        let sampler = ThermalSampler(brand: "Apple M1 Pro", makeTransport: { smc })
        _ = await sampler.sample(now: now)
        _ = await sampler.sample(now: now.addingTimeInterval(4))
        XCTAssertTrue(smc.commandsSent.isSubset(of: [5, 8, 9]), "\(smc.commandsSent)")
        XCTAssertGreaterThan(smc.calls(command: 5, key: "F0Ac"), 0)
    }

    func testTransportGuardAllowsOnlyReadCommands() {
        for command: UInt8 in [5, 8, 9] {
            var frame = [UInt8](repeating: 0, count: 80)
            frame[42] = command
            XCTAssertTrue(SMCCommand.isPermitted(frame), "\(command)")
        }
        for command: UInt8 in [0, 6, 7, 10, 255] {
            var frame = [UInt8](repeating: 0, count: 80)
            frame[42] = command
            XCTAssertFalse(SMCCommand.isPermitted(frame), "\(command)")
        }
        XCTAssertFalse(SMCCommand.isPermitted([UInt8](repeating: 5, count: 79)))
    }

    func testUnmappedMacSaysSoInsteadOfWaiting() async {
        let sampler = ThermalSampler(brand: "Unknown CPU", makeTransport: { XCTFail("No sensors to read"); return nil })
        let snapshot = await sampler.sample(now: now)
        XCTAssertEqual(snapshot.unavailableReason, "Sensor mapping is not verified for this Mac")
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot, activity: .empty,
            pressure: ThermalPressureReading(state: .normal, sampledAt: now), at: now)
        XCTAssertEqual(diagnosis.reviewStatus, "Sensors unsupported")
        XCTAssertEqual(diagnosis.headline,
                       "Temperature sensors aren't mapped for this Mac yet — showing macOS thermal pressure instead")
        XCTAssertTrue(diagnosis.explanation.contains("Sensor mapping is not verified for this Mac"))

        let stale = ThermalDiagnosis.evaluate(snapshot: snapshot, activity: .empty, at: now.addingTimeInterval(16))
        XCTAssertEqual(stale.headline, "Waiting for a current temperature reading")
        let starting = ThermalDiagnosis.evaluate(snapshot: .unknown, activity: .empty, at: now)
        XCTAssertEqual(starting.reviewStatus, "Checking")
    }

    func testMappedSensorsThatFailToReadAreNotCalledUnsupported() {
        let snapshot = ThermalSnapshot(sampledAt: now, cpuCelsius: nil, gpuCelsius: nil, sensorCount: 0, sensorKeys: [],
            systemState: "Nominal", unavailableReason: "Hardware sensors could not be read", mappingSource: .verified)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot, activity: .empty, at: now)
        XCTAssertEqual(diagnosis.reviewStatus, "Sensors unavailable")
        XCTAssertTrue(diagnosis.headline.hasPrefix("Temperature sensors couldn't be read"))
    }
}

/// An SMC that answers key-info, read and index commands from a table.
private final class FakeSMC: SMCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let keys: [String]
    private let values: [String: Float]
    private let types: [String: (String, Int)]
    /// Raw payloads for keys whose encoding is not a little-endian float.
    private let bytes: [String: [UInt8]]
    private let reportedKeyCount: Int
    private var log: [(command: UInt8, key: String)] = []

    init(values: [String: Float], types: [String: (String, Int)] = [:], bytes: [String: [UInt8]] = [:],
         extraKeys: [String] = [], reportedKeyCount: Int? = nil) {
        self.values = values
        self.types = types
        self.bytes = bytes
        keys = (values.keys.sorted() + extraKeys)
        self.reportedKeyCount = reportedKeyCount ?? keys.count
    }

    func calls(command: UInt8, key: String? = nil) -> Int {
        lock.withLock { log.filter { $0.command == command && (key == nil || $0.key == key) }.count }
    }

    var commandsSent: Set<UInt8> {
        lock.withLock { Set(log.map(\.command)) }
    }

    func call(_ input: [UInt8]) -> SMCCallResult {
        let command = input[42]
        let key = Self.text(SMCTemperatureCodec.word(input, at: 0))
        lock.withLock { log.append((command, key)) }
        var output = [UInt8](repeating: 0, count: 80)
        switch command {
        case 8:
            let index = Int(SMCTemperatureCodec.word(input, at: 44))
            guard index < keys.count else { return .smcError(0x84) }
            SMCTemperatureCodec.put(SMCTemperatureCodec.fourCC(keys[index]), into: &output, at: 0)
        case 9:
            let (type, size): (String, Int)
            if key == "#KEY" {
                (type, size) = ("ui32", 4)
            } else if let known = types[key] {
                (type, size) = known
            } else if values[key] != nil {
                (type, size) = ("flt ", 4)
            } else {
                return .smcError(0x84)
            }
            SMCTemperatureCodec.put(UInt32(size), into: &output, at: 28)
            SMCTemperatureCodec.put(SMCTemperatureCodec.fourCC(type), into: &output, at: 32)
        case 5:
            if key == "#KEY" {
                let count = UInt32(reportedKeyCount)
                for offset in 0..<4 { output[48 + offset] = UInt8(truncatingIfNeeded: count >> ((3 - offset) * 8)) }
            } else if let raw = bytes[key] {
                for (offset, byte) in raw.enumerated() { output[48 + offset] = byte }
            } else if let value = values[key] {
                SMCTemperatureCodec.put(value.bitPattern, into: &output, at: 48)
            } else if types[key] != nil {
                output[48] = 1
            } else {
                return .smcError(0x84)
            }
        default:
            return .transportFailure(-1)
        }
        return .ok(output)
    }

    private static func text(_ code: UInt32) -> String {
        String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: code >> ((3 - $0) * 8)) }, as: UTF8.self)
    }
}
