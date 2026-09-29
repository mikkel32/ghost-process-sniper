import Foundation

public struct ThermalSnapshot: Equatable, Sendable {
    public let sampledAt: Date
    public let cpuCelsius: Double?
    public let gpuCelsius: Double?
    public let sensorCount: Int
    public let sensorKeys: [String]
    public let systemState: String
    public let unavailableReason: String?
    /// The sensor that produced the reported maximum; it rotates between cores under load.
    public let cpuSensorKey: String?
    public let gpuSensorKey: String?
    /// Identifies the set of sensors behind the maximum, so a trend survives the
    /// hottest core moving and resets only when the readable set itself changes.
    public let cpuSeriesID: String?
    public let gpuSeriesID: String?
    /// Where the sensor key map came from; nil when this Mac has none.
    public let mappingSource: SMCSensorMapping.Source?
    /// Read-only fan speeds; empty on a Mac without fans or when they could not be read.
    public let fans: [ThermalFan]

    public init(sampledAt: Date, cpuCelsius: Double?, gpuCelsius: Double?, sensorCount: Int,
                sensorKeys: [String], systemState: String, unavailableReason: String?,
                cpuSensorKey: String? = nil, gpuSensorKey: String? = nil,
                cpuSeriesID: String? = nil, gpuSeriesID: String? = nil,
                mappingSource: SMCSensorMapping.Source? = nil, fans: [ThermalFan] = []) {
        self.sampledAt = sampledAt
        self.cpuCelsius = cpuCelsius
        self.gpuCelsius = gpuCelsius
        self.sensorCount = sensorCount
        self.sensorKeys = sensorKeys
        self.systemState = systemState
        self.unavailableReason = unavailableReason
        self.cpuSensorKey = cpuSensorKey
        self.gpuSensorKey = gpuSensorKey
        self.cpuSeriesID = cpuSeriesID
        self.gpuSeriesID = gpuSeriesID
        self.mappingSource = mappingSource
        self.fans = fans
    }

    /// A caveat for key maps not yet confirmed on real hardware of this chip family.
    public var mappingNote: String? {
        switch mappingSource {
        case .catalog: "Sensor map from the chip catalog; not yet verified on this model"
        case .discovered: "Sensors found automatically on this Mac; readings are best effort"
        case .verified, nil: nil
        }
    }

    /// After this instant the readings no longer count as current.
    public var expiresAt: Date { sampledAt.addingTimeInterval(15) }

    var cpuSeries: String? { cpuSeriesID ?? cpuSensorKey }
    var gpuSeries: String? { gpuSeriesID ?? gpuSensorKey }

    public static let unknown = ThermalSnapshot(sampledAt: .distantPast, cpuCelsius: nil, gpuCelsius: nil, sensorCount: 0, sensorKeys: [], systemState: "Waiting", unavailableReason: "Waiting for hardware sensors")

    public func temperatureText(_ value: Double?, at now: Date = Date()) -> String {
        guard (0...15).contains(now.timeIntervalSince(sampledAt)), let value, value.isFinite else { return "Unavailable" }
        return RadarFormat.celsius(value)
    }

    /// The fan line, or nil without fans and once the reading is no longer current,
    /// so an old rpm never sits beside an "Unavailable" temperature.
    public func fanText(at now: Date = Date()) -> String? {
        guard (0...15).contains(now.timeIntervalSince(sampledAt)) else { return nil }
        return ThermalFan.summary(fans)
    }
}

enum SMCTemperatureCodec {
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            value = float32(bytes)
        case "sp78":
            guard bytes.count == 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
        // Zero, sentinels, NaN, and unsupported encodings are not temperatures.
        return value.isFinite && (5...125).contains(value) ? value : nil
    }

    /// Plain numbers such as fan counts and speeds: `flt ` (little-endian), `fpe2`
    /// (unsigned 14.2 fixed point, big-endian, on older Intel Macs) and `ui8 `.
    /// Range checks belong to the caller; only non-finite values are refused here.
    static func decodeNumber(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            value = float32(bytes)
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ":
            guard bytes.count == 1 else { return nil }
            value = Double(bytes[0])
        default: return nil
        }
        return value.isFinite ? value : nil
    }

    private static func float32(_ bytes: [UInt8]) -> Double {
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Double(Float(bitPattern: bits))
    }

    static func fourCC(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
}

/// Read-only AppleSMC telemetry. No writes, fan controls, sudo, or helper daemon.
/// The SMC wire ABI and model-specific key map are not a public Apple API;
/// unsupported hardware fails to an explicit unavailable state.
public actor ThermalSampler {
    private let brand: String
    private let makeTransport: @Sendable () -> (any SMCTransport)?
    private var reader: SMCKeyReader?
    private var mapping: SMCSensorMapping?
    private var discoveryAttempted = false
    private var lastAttempt = Date.distantPast
    private var snapshot = ThermalSnapshot.unknown

    public init() {
        self.init(brand: Self.processorBrand(), makeTransport: { IOKitSMCTransport.open() })
    }

    init(brand: String, makeTransport: @escaping @Sendable () -> (any SMCTransport)?) {
        self.brand = brand
        self.makeTransport = makeTransport
        mapping = SMCSensorCatalog.mapping(forBrand: brand)
    }

    public func sample(now: Date = Date()) -> ThermalSnapshot {
        let elapsed = now.timeIntervalSince(lastAttempt)
        if elapsed >= 0 && elapsed < 3 { return snapshot }
        lastAttempt = now
        let isAppleSilicon = SMCSensorCatalog.generation(fromBrand: brand) != nil
        if reader == nil, mapping != nil || isAppleSilicon, let transport = makeTransport() {
            reader = SMCKeyReader(transport: transport)
        }
        if mapping == nil, isAppleSilicon, !discoveryAttempted, reader != nil {
            // Enumerating the SMC costs a few thousand calls, so it runs once per launch.
            discoveryAttempted = true
            mapping = reader?.discoverMapping()
        }
        let cpu = readings(mapping?.cpuKeys ?? [])
        let gpu = readings(mapping?.gpuKeys ?? [])
        let keys = (cpu + gpu).map(\.0)
        let hottestCPU = cpu.max { $0.1 < $1.1 }
        let hottestGPU = gpu.max { $0.1 < $1.1 }
        // Independent of the temperature map: a chip without one can still report fans.
        let fans = reader?.fanSpeeds() ?? []
        snapshot = ThermalSnapshot(
            sampledAt: now,
            cpuCelsius: hottestCPU?.1,
            gpuCelsius: hottestGPU?.1,
            sensorCount: keys.count,
            sensorKeys: keys,
            systemState: ThermalPressureReading.current(at: now).systemStateLabel,
            unavailableReason: keys.isEmpty ? unavailableReason(isAppleSilicon: isAppleSilicon) : nil,
            cpuSensorKey: hottestCPU?.0,
            gpuSensorKey: hottestGPU?.0,
            cpuSeriesID: Self.seriesID("cpu", cpu),
            gpuSeriesID: Self.seriesID("gpu", gpu),
            mappingSource: mapping?.source,
            fans: fans
        )
        return snapshot
    }

    private func unavailableReason(isAppleSilicon: Bool) -> String {
        if mapping != nil || (isAppleSilicon && reader == nil) { return "Hardware sensors could not be read" }
        return discoveryAttempted ? "No readable temperature sensors were found on this Mac"
            : "Sensor mapping is not verified for this Mac"
    }

    private func readings(_ keys: [String]) -> [(String, Double)] {
        guard reader != nil else { return [] }
        return keys.compactMap { key in reader?.temperature(key).map { (key, $0) } }
    }

    private static func seriesID(_ component: String, _ readings: [(String, Double)]) -> String? {
        readings.isEmpty ? nil : component + ":" + readings.map(\.0).sorted().joined(separator: ",")
    }

    private static func processorBrand() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
