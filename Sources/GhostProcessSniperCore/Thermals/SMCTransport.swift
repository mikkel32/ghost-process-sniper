import Foundation
import IOKit

public enum SMCCallResult: Equatable, Sendable {
    case ok([UInt8])
    /// The call reached the SMC, which answered with a nonzero result byte.
    case smcError(UInt8)
    case transportFailure(Int32)
}

/// One 80-byte SMCKeyData exchange. Injected so key reads and discovery can be
/// exercised without hardware.
public protocol SMCTransport: Sendable {
    func call(_ input: [UInt8]) -> SMCCallResult
}

/// The only SMC commands this app sends. All of them read; none writes.
enum SMCCommand: UInt8 {
    case readBytes = 5
    case readIndex = 8
    case readKeyInfo = 9

    static let frameSize = 80
    // SMCKeyData ABI: key=0, keyInfo=28, result=40, data8=42, data32=44, bytes=48.
    static let commandOffset = 42

    static func isPermitted(_ input: [UInt8]) -> Bool {
        input.count == frameSize && SMCCommand(rawValue: input[commandOffset]) != nil
    }
}

final class IOKitSMCTransport: SMCTransport {
    private let connection: io_connect_t

    private init(connection: io_connect_t) {
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    static func open() -> IOKitSMCTransport? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess, connection != 0 else { return nil }
        return IOKitSMCTransport(connection: connection)
    }

    func call(_ input: [UInt8]) -> SMCCallResult {
        // The read-only guarantee lives here, next to the hardware call.
        guard SMCCommand.isPermitted(input) else { return .transportFailure(-1) }
        var output = [UInt8](repeating: 0, count: SMCCommand.frameSize)
        var outputSize = SMCCommand.frameSize
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, SMCCommand.frameSize,
                                          destination.baseAddress, &outputSize)
            }
        }
        guard result == kIOReturnSuccess else { return .transportFailure(result) }
        guard outputSize == SMCCommand.frameSize else { return .transportFailure(-1) }
        // Key-not-found (0x84) arrives as a successful IOKit call with a result byte.
        return output[40] == 0 ? .ok(output) : .smcError(output[40])
    }
}

/// Reads typed SMC values and remembers which keys this Mac does not have.
struct SMCKeyReader {
    static let keyNotFound: UInt8 = 0x84
    static let maximumDiscoveryIndices = 4_096
    static let maximumDiscoveredPerComponent = 24

    struct KeyInfo: Equatable {
        let size: Int
        let type: String
    }

    static let maximumFans = 4
    /// Above any real fan; a larger value is a sentinel or garbage, not a speed.
    static let maximumPlausibleRPM = 20_000.0

    let transport: any SMCTransport
    private var metadata: [String: KeyInfo] = [:]
    private(set) var unsupportedKeys: Set<String> = []
    // Neither the number of fans nor a fan's maximum changes while the Mac runs.
    private var fanCount: Int?
    private var fanMaximums: [Int: Double] = [:]

    init(transport: any SMCTransport) {
        self.transport = transport
    }

    mutating func temperature(_ key: String) -> Double? {
        guard let info = info(key) else { return nil }
        guard (info.type == "flt " && info.size == 4) || (info.type == "sp78" && info.size == 2) else {
            unsupportedKeys.insert(key)
            return nil
        }
        guard let bytes = read(key, info: info) else { return nil }
        return SMCTemperatureCodec.decode(type: info.type, bytes: bytes)
    }

    /// Current speed of every fan, read-only (FNum, F<n>Ac, F<n>Mx through the same
    /// three read commands as the temperatures). Empty for a Mac without fans, which
    /// has no FNum or reports none, and whenever a fan's speed cannot be trusted:
    /// one unreadable fan must not let the others claim "idle". The key names and
    /// types are the widely documented ones and are not yet verified on this
    /// project's hardware, so anything unexpected hides the row instead of guessing.
    mutating func fanSpeeds() -> [ThermalFan] {
        if fanCount == nil, let count = number("FNum", types: ["ui8 "], within: 0...255) {
            fanCount = min(Int(count), Self.maximumFans)
        }
        guard let count = fanCount, count > 0 else { return [] }
        var fans: [ThermalFan] = []
        for index in 0..<count {
            guard let rpm = fanRPM("F\(index)Ac") else { return [] }
            if fanMaximums[index] == nil, let maximum = fanRPM("F\(index)Mx"), maximum > 0 {
                fanMaximums[index] = maximum
            }
            fans.append(ThermalFan(rpm: rpm, maximumRPM: fanMaximums[index]))
        }
        return fans
    }

    /// Walks the SMC key index once for chips without a catalog entry. Only die
    /// sensor prefixes are trusted: an M3-style layout that reports CPU cores as
    /// Tf keys stays unmapped rather than being guessed.
    mutating func discoverMapping() -> SMCSensorMapping? {
        guard let countInfo = info("#KEY"), countInfo.type == "ui32", countInfo.size == 4,
              let countBytes = read("#KEY", info: countInfo) else { return nil }
        let count = countBytes.reduce(0) { ($0 << 8) | Int($1) }
        var cpu: [String] = []
        var gpu: [String] = []
        for index in 0..<min(count, Self.maximumDiscoveryIndices) {
            guard cpu.count < Self.maximumDiscoveredPerComponent || gpu.count < Self.maximumDiscoveredPerComponent else { break }
            guard let key = key(at: UInt32(index)) else { continue }
            let isCPU = key.hasPrefix("Tp") || key.hasPrefix("Te")
            let isGPU = key.hasPrefix("Tg")
            guard (isCPU && cpu.count < Self.maximumDiscoveredPerComponent) ||
                    (isGPU && gpu.count < Self.maximumDiscoveredPerComponent),
                  let info = info(key), info.type == "flt ", info.size == 4,
                  let bytes = read(key, info: info),
                  let value = SMCTemperatureCodec.decode(type: info.type, bytes: bytes),
                  (20...110).contains(value) else { continue }
            if isCPU { cpu.append(key) } else { gpu.append(key) }
        }
        guard !cpu.isEmpty || !gpu.isEmpty else { return nil }
        return SMCSensorMapping(cpuKeys: cpu, gpuKeys: gpu, source: .discovered)
    }

    private mutating func fanRPM(_ key: String) -> Double? {
        number(key, types: ["flt ", "fpe2"], within: 0...Self.maximumPlausibleRPM)
    }

    /// A plain number of one of the given types, or nil when the key is missing,
    /// unreadable, of another type or outside the plausible range.
    private mutating func number(_ key: String, types: Set<String>, within range: ClosedRange<Double>) -> Double? {
        guard let info = info(key), types.contains(info.type), let bytes = read(key, info: info),
              let value = SMCTemperatureCodec.decodeNumber(type: info.type, bytes: bytes),
              range.contains(value) else { return nil }
        return value
    }

    private mutating func info(_ key: String) -> KeyInfo? {
        if let known = metadata[key] { return known }
        guard key.utf8.count == 4, !unsupportedKeys.contains(key) else { return nil }
        switch transport.call(Self.frame(key: key, command: .readKeyInfo)) {
        case .ok(let output):
            let code = SMCTemperatureCodec.word(output, at: 32)
            let info = KeyInfo(size: Int(SMCTemperatureCodec.word(output, at: 28)), type: Self.fourCharacterText(code))
            metadata[key] = info
            return info
        case .smcError(Self.keyNotFound):
            // The SMC will not grow this key later; asking every sample only costs calls.
            unsupportedKeys.insert(key)
            return nil
        case .smcError, .transportFailure:
            return nil
        }
    }

    private func read(_ key: String, info: KeyInfo) -> [UInt8]? {
        guard (1...32).contains(info.size),
              case .ok(let output) = transport.call(Self.frame(key: key, command: .readBytes, size: info.size))
        else { return nil }
        return Array(output[48..<(48 + info.size)])
    }

    private func key(at index: UInt32) -> String? {
        var input = Self.frame(key: nil, command: .readIndex)
        SMCTemperatureCodec.put(index, into: &input, at: 44)
        guard case .ok(let output) = transport.call(input) else { return nil }
        let key = Self.fourCharacterText(SMCTemperatureCodec.word(output, at: 0))
        return key.utf8.count == 4 && key.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) ? key : nil
    }

    private static func frame(key: String?, command: SMCCommand, size: Int = 0) -> [UInt8] {
        var input = [UInt8](repeating: 0, count: SMCCommand.frameSize)
        if let key { SMCTemperatureCodec.put(SMCTemperatureCodec.fourCC(key), into: &input, at: 0) }
        SMCTemperatureCodec.put(UInt32(size), into: &input, at: 28)
        input[SMCCommand.commandOffset] = command.rawValue
        return input
    }

    private static func fourCharacterText(_ code: UInt32) -> String {
        String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: code >> ((3 - $0) * 8)) }, as: UTF8.self)
    }
}
