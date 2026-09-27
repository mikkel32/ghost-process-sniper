import Foundation
import IOKit

/// One read of the battery and the Mac's power draw. Every field is optional:
/// desktops have no battery, Intel Macs have no power telemetry, and a key
/// macOS stops publishing reads as unknown, never as zero.
public struct BatteryReading: Equatable, Sendable {
    public var hasBattery: Bool
    public var onExternalPower: Bool
    public var isCharging: Bool
    /// The charge macOS shows in the menu bar, 0–100.
    public var chargePercent: Double?
    public var currentCapacityMilliampHours: Double?
    public var fullChargeCapacityMilliampHours: Double?
    public var designCapacityMilliampHours: Double?
    public var voltageMillivolts: Double?
    /// Signed: negative while the battery discharges.
    public var amperageMilliamps: Double?
    /// The whole Mac's draw, display and GPU included (Apple silicon laptops).
    public var systemLoadWatts: Double?
    /// What the battery itself delivers while discharging.
    public var batteryDischargeWatts: Double?
    public var adapterInputWatts: Double?
    public var cycleCount: Int?
    public var temperatureCelsius: Double?
    public var readAt: Date

    public static let none = BatteryReading(hasBattery: false, onExternalPower: true, isCharging: false, readAt: .distantPast)

    public init(
        hasBattery: Bool, onExternalPower: Bool, isCharging: Bool,
        chargePercent: Double? = nil, currentCapacityMilliampHours: Double? = nil,
        fullChargeCapacityMilliampHours: Double? = nil, designCapacityMilliampHours: Double? = nil,
        voltageMillivolts: Double? = nil, amperageMilliamps: Double? = nil,
        systemLoadWatts: Double? = nil, batteryDischargeWatts: Double? = nil, adapterInputWatts: Double? = nil,
        cycleCount: Int? = nil, temperatureCelsius: Double? = nil, readAt: Date
    ) {
        self.hasBattery = hasBattery
        self.onExternalPower = onExternalPower
        self.isCharging = isCharging
        self.chargePercent = chargePercent
        self.currentCapacityMilliampHours = currentCapacityMilliampHours
        self.fullChargeCapacityMilliampHours = fullChargeCapacityMilliampHours
        self.designCapacityMilliampHours = designCapacityMilliampHours
        self.voltageMillivolts = voltageMillivolts
        self.amperageMilliamps = amperageMilliamps
        self.systemLoadWatts = systemLoadWatts
        self.batteryDischargeWatts = batteryDischargeWatts
        self.adapterInputWatts = adapterInputWatts
        self.cycleCount = cycleCount
        self.temperatureCelsius = temperatureCelsius
        self.readAt = readAt
    }

    public var isDischarging: Bool { hasBattery && !onExternalPower }

    /// Energy left in the battery, from its raw capacity and voltage.
    public var remainingWattHours: Double? {
        guard let capacity = currentCapacityMilliampHours, let volts = voltageMillivolts,
              capacity > 0, volts > 0 else { return nil }
        return capacity * volts / 1_000_000
    }

    /// What a full charge holds today.
    public var fullChargeWattHours: Double? {
        guard let capacity = fullChargeCapacityMilliampHours, let volts = voltageMillivolts,
              capacity > 0, volts > 0 else { return nil }
        return capacity * volts / 1_000_000
    }

    /// How much of its design capacity the battery still holds.
    public var healthPercent: Double? {
        guard let full = fullChargeCapacityMilliampHours, let design = designCapacityMilliampHours,
              full > 0, design > 0 else { return nil }
        return min(100, full / design * 100)
    }

    /// The Mac's whole draw right now: the battery's output while discharging,
    /// otherwise the system load the power controller reports.
    public var drawWatts: Double? {
        if isDischarging {
            if let discharge = batteryDischargeWatts, discharge > 0 { return discharge }
            if let amps = amperageMilliamps, let volts = voltageMillivolts, amps < 0 {
                return -amps * volts / 1_000_000
            }
        }
        if let load = systemLoadWatts, load > 0 { return load }
        return nil
    }
}

/// Reads AppleSmartBattery's registry properties. Injected so the energy
/// analysis can run against scripted batteries in tests.
public protocol BatterySource: Sendable {
    func read(now: Date) -> BatteryReading
}

/// Reads only the keys it needs, one property at a time, so a read never copies
/// the battery's whole (large) property table. Read-only; no privileges.
public struct IOKitBatterySource: BatterySource {
    public init() {}

    public func read(now: Date) -> BatteryReading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return BatteryReading(hasBattery: false, onExternalPower: true, isCharging: false, readAt: now) }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
        }
        let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        func milliwatts(_ key: String) -> Double? {
            (telemetry?[key] as? NSNumber).map { $0.doubleValue / 1_000 }
        }
        let batteryInstalled = number("BatteryInstalled")?.boolValue ?? true
        // Apple silicon reports CurrentCapacity as a percentage and the raw mAh
        // separately; Intel reports mAh in CurrentCapacity and MaxCapacity.
        let rawCurrent = number("AppleRawCurrentCapacity")?.doubleValue
        let rawMax = number("AppleRawMaxCapacity")?.doubleValue
        let current = number("CurrentCapacity")?.doubleValue
        let maximum = number("MaxCapacity")?.doubleValue
        let percent: Double? = if let current, let maximum, maximum > 0 { min(100, current / maximum * 100) } else { nil }
        let temperature = number("Temperature").map { $0.doubleValue / 100 }
        return BatteryReading(
            hasBattery: batteryInstalled,
            onExternalPower: number("ExternalConnected")?.boolValue ?? false,
            isCharging: number("IsCharging")?.boolValue ?? false,
            chargePercent: percent,
            currentCapacityMilliampHours: rawCurrent ?? (maximum.map { $0 > 100 } == true ? current : nil),
            fullChargeCapacityMilliampHours: rawMax ?? (maximum.map { $0 > 100 } == true ? maximum : nil),
            designCapacityMilliampHours: number("DesignCapacity")?.doubleValue,
            voltageMillivolts: number("Voltage")?.doubleValue,
            // int64Value turns the registry's wrapped unsigned value back into a signed one.
            amperageMilliamps: (number("InstantAmperage") ?? number("Amperage")).map { Double($0.int64Value) },
            systemLoadWatts: milliwatts("SystemLoad"),
            batteryDischargeWatts: milliwatts("BatteryPower"),
            adapterInputWatts: milliwatts("SystemPowerIn"),
            cycleCount: number("CycleCount")?.intValue,
            temperatureCelsius: temperature.flatMap { (0...90).contains($0) ? $0 : nil },
            readAt: now
        )
    }
}
