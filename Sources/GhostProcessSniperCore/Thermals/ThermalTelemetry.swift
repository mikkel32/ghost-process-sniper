import Foundation
import IOKit

public struct ThermalSnapshot: Equatable, Sendable {
    public let sampledAt: Date
    public let cpuCelsius: Double?
    public let gpuCelsius: Double?
    public let sensorCount: Int
    public let sensorKeys: [String]
    public let systemState: String
    public let unavailableReason: String?
    public let cpuSensorKey: String?
    public let gpuSensorKey: String?

    public init(sampledAt: Date, cpuCelsius: Double?, gpuCelsius: Double?, sensorCount: Int,
                sensorKeys: [String], systemState: String, unavailableReason: String?,
                cpuSensorKey: String? = nil, gpuSensorKey: String? = nil) {
        self.sampledAt = sampledAt
        self.cpuCelsius = cpuCelsius
        self.gpuCelsius = gpuCelsius
        self.sensorCount = sensorCount
        self.sensorKeys = sensorKeys
        self.systemState = systemState
        self.unavailableReason = unavailableReason
        self.cpuSensorKey = cpuSensorKey
        self.gpuSensorKey = gpuSensorKey
    }

    public static let unknown = ThermalSnapshot(sampledAt: .distantPast, cpuCelsius: nil, gpuCelsius: nil, sensorCount: 0, sensorKeys: [], systemState: "Waiting", unavailableReason: "Waiting for hardware sensors")

    public func temperatureText(_ value: Double?, at now: Date = Date()) -> String {
        guard (0...15).contains(now.timeIntervalSince(sampledAt)), let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.1f°C", value)
    }
}

enum SMCTemperatureCodec {
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            value = Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
        // Zero, sentinels, NaN, and unsupported encodings are not temperatures.
        return value.isFinite && (5...125).contains(value) ? value : nil
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
    private var connection: io_connect_t = 0
    private var lastAttempt = Date.distantPast
    private var snapshot = ThermalSnapshot.unknown
    private var metadata: [String: (size: Int, type: String)] = [:]
    private var unsupportedKeys: Set<String> = []
    private let cpuKeys: [String]
    private let gpuKeys: [String]

    public init() {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let brand = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if brand.contains("Apple M1") {
            cpuKeys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
            gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else if brand.contains("Apple M2") {
            cpuKeys = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
            gpuKeys = ["Tg0f", "Tg0j"]
        } else if brand.contains("Intel") {
            cpuKeys = ["TC0D", "TC0P"]
            gpuKeys = ["TG0D", "TG0P"]
        } else {
            // A key reused on another chip can represent a different sensor.
            cpuKeys = []
            gpuKeys = []
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    public func sample(now: Date = Date()) -> ThermalSnapshot {
        let elapsed = now.timeIntervalSince(lastAttempt)
        if elapsed >= 0 && elapsed < 3 { return snapshot }
        lastAttempt = now
        if connection == 0 { openConnection() }
        let cpu = readings(cpuKeys)
        let gpu = readings(gpuKeys)
        let keys = (cpu + gpu).map(\.0)
        let state: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = "Nominal"
        case .fair: state = "Elevated"
        case .serious: state = "Serious"
        case .critical: state = "Critical"
        @unknown default: state = "Unknown"
        }
        let hottestCPU = cpu.max { $0.1 < $1.1 }
        let hottestGPU = gpu.max { $0.1 < $1.1 }
        snapshot = ThermalSnapshot(
            sampledAt: now,
            cpuCelsius: hottestCPU?.1,
            gpuCelsius: hottestGPU?.1,
            sensorCount: keys.count,
            sensorKeys: keys,
            systemState: state,
            unavailableReason: keys.isEmpty ? (cpuKeys.isEmpty ? "Sensor mapping is not verified for this Mac" : "Hardware sensors could not be read") : nil,
            cpuSensorKey: hottestCPU?.0,
            gpuSensorKey: hottestGPU?.0
        )
        return snapshot
    }

    private func openConnection() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess { connection = 0 }
    }

    private func readings(_ keys: [String]) -> [(String, Double)] {
        guard connection != 0 else { return [] }
        return keys.compactMap { key in readTemperature(key).map { (key, $0) } }
    }

    private func readTemperature(_ key: String) -> Double? {
        guard !unsupportedKeys.contains(key) else { return nil }
        if metadata[key] == nil {
            guard let info = transact(key: key, command: 9, size: 0) else { return nil }
            let size = Int(SMCTemperatureCodec.word(info, at: 28))
            let code = SMCTemperatureCodec.word(info, at: 32)
            let typeBytes = (0..<4).map { UInt8(truncatingIfNeeded: code >> ((3 - $0) * 8)) }
            let type = String(decoding: typeBytes, as: UTF8.self)
            guard (type == "flt " && size == 4) || (type == "sp78" && size == 2) else {
                unsupportedKeys.insert(key)
                return nil
            }
            metadata[key] = (size, type)
        }
        guard let info = metadata[key], let output = transact(key: key, command: 5, size: info.size) else { return nil }
        return SMCTemperatureCodec.decode(type: info.type, bytes: Array(output[48..<(48 + info.size)]))
    }

    private func transact(key: String, command: UInt8, size: Int) -> [UInt8]? {
        guard key.utf8.count == 4, command == 5 || command == 9 else { return nil }
        // SMCKeyData ABI: key=0, keyInfo=28, result=40, data8=42, bytes=48.
        var input = [UInt8](repeating: 0, count: 80)
        var output = input
        SMCTemperatureCodec.put(SMCTemperatureCodec.fourCC(key), into: &input, at: 0)
        SMCTemperatureCodec.put(UInt32(size), into: &input, at: 28)
        input[42] = command
        var outputSize = 80
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, destination.baseAddress, &outputSize)
            }
        }
        guard result == kIOReturnSuccess, outputSize == 80, output[40] == 0 else { return nil }
        return output
    }
}
