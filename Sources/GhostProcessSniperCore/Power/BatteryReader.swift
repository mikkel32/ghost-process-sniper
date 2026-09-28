import Foundation
import IOKit

/// A running total the power controller keeps of one measure: the sum of its
/// samples (milliwatts) and how many it has taken, about one a second. Two
/// readings give the exact mean between them, however often the registry
/// publishes and whatever the load did in between.
public struct PowerAccumulator: Equatable, Sendable {
    public var sum: Double
    public var samples: Double

    public init(sum: Double, samples: Double) {
        self.sum = sum
        self.samples = samples
    }

    /// The mean between two readings, in watts. Nil when nothing new was
    /// counted, the counter went backwards (a reset) or the mean is not a
    /// plausible draw.
    public static func averageWatts(from old: PowerAccumulator, to new: PowerAccumulator) -> Double? {
        let samples = new.samples - old.samples
        guard samples >= 1 else { return nil }
        let watts = (new.sum - old.sum) / samples / 1_000
        return BatteryReading.isPlausibleDraw(watts) ? watts : nil
    }
}

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
    /// The smoothed full-charge capacity macOS derives its Maximum Capacity
    /// from. The raw maximum above moves with charge state and temperature.
    public var nominalChargeCapacityMilliampHours: Double?
    public var voltageMillivolts: Double?
    /// Signed: negative while the battery discharges.
    public var amperageMilliamps: Double?
    /// The whole Mac's draw, display and GPU included (Apple silicon laptops).
    public var systemLoadWatts: Double?
    /// What the battery itself delivers while discharging; nil unless power is leaving it.
    public var batteryDischargeWatts: Double?
    /// What the wall delivers this second: the Mac's load plus whatever goes
    /// into the battery. It moves with the work, so it is not the charger's size.
    public var adapterInputWatts: Double?
    /// What the charger negotiated with the Mac, the most it can supply.
    public var adapterRatedWatts: Double?
    /// The controller's running total of `SystemLoad`, for interval means.
    public var systemLoadAccumulator: PowerAccumulator?
    public var cycleCount: Int?
    public var temperatureCelsius: Double?
    public var readAt: Date

    public static let none = BatteryReading(hasBattery: false, onExternalPower: true, isCharging: false, readAt: .distantPast)

    public init(
        hasBattery: Bool, onExternalPower: Bool, isCharging: Bool,
        chargePercent: Double? = nil, currentCapacityMilliampHours: Double? = nil,
        fullChargeCapacityMilliampHours: Double? = nil, designCapacityMilliampHours: Double? = nil,
        nominalChargeCapacityMilliampHours: Double? = nil, voltageMillivolts: Double? = nil, amperageMilliamps: Double? = nil,
        systemLoadWatts: Double? = nil, batteryDischargeWatts: Double? = nil, adapterInputWatts: Double? = nil,
        adapterRatedWatts: Double? = nil, systemLoadAccumulator: PowerAccumulator? = nil,
        cycleCount: Int? = nil, temperatureCelsius: Double? = nil, readAt: Date
    ) {
        self.hasBattery = hasBattery
        self.onExternalPower = onExternalPower
        self.isCharging = isCharging
        self.chargePercent = chargePercent
        self.currentCapacityMilliampHours = currentCapacityMilliampHours
        self.fullChargeCapacityMilliampHours = fullChargeCapacityMilliampHours
        self.designCapacityMilliampHours = designCapacityMilliampHours
        self.nominalChargeCapacityMilliampHours = nominalChargeCapacityMilliampHours
        self.voltageMillivolts = voltageMillivolts
        self.amperageMilliamps = amperageMilliamps
        self.systemLoadWatts = systemLoadWatts
        self.batteryDischargeWatts = batteryDischargeWatts
        self.adapterInputWatts = adapterInputWatts
        self.adapterRatedWatts = adapterRatedWatts
        self.systemLoadAccumulator = systemLoadAccumulator
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

    /// How much of its design capacity the battery still holds, from the
    /// capacity macOS derives Maximum Capacity from, or the raw maximum where
    /// a Mac has none. (macOS rounds the same figure its own way, so the
    /// whole percent can differ by one.)
    public var healthPercent: Double? {
        let nominal = nominalChargeCapacityMilliampHours.flatMap { $0 > 0 ? $0 : nil }
        guard let full = nominal ?? fullChargeCapacityMilliampHours, let design = designCapacityMilliampHours,
              full > 0, design > 0 else { return nil }
        return min(100, full / design * 100)
    }

    /// Watts going into the battery (positive) or out of it (negative), from
    /// the same signed current the registry reports. Independent of the
    /// IsCharging flag, which says what macOS is attempting, not what happens.
    public var netBatteryWatts: Double? {
        guard let amps = amperageMilliamps, let volts = voltageMillivolts, volts > 0 else { return nil }
        return amps * volts / 1_000_000
    }

    /// The most a Mac draws; anything above is a garbled reading, not a load.
    static let maximumPlausibleWatts = 400.0

    static func isPlausibleDraw(_ watts: Double) -> Bool {
        watts.isFinite && watts > 0 && watts <= maximumPlausibleWatts
    }

    /// The Mac's whole draw right now: the battery's output while discharging,
    /// otherwise the system load the power controller reports. A wrapped,
    /// negative or absurd figure is skipped for the next source.
    public var drawWatts: Double? {
        if isDischarging {
            if let discharge = batteryDischargeWatts, Self.isPlausibleDraw(discharge) { return discharge }
            if let amps = amperageMilliamps, let volts = voltageMillivolts, amps < 0 {
                let out = -amps * volts / 1_000_000
                if Self.isPlausibleDraw(out) { return out }
            }
        }
        if let load = systemLoadWatts, Self.isPlausibleDraw(load) { return load }
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
        // Signed: int64Value turns a wrapped unsigned value back into a negative one.
        func telemetryValue(_ key: String) -> Double? {
            (telemetry?[key] as? NSNumber).map { Double($0.int64Value) }
        }
        func watts(_ key: String) -> Double? { telemetryValue(key).map { $0 / 1_000 } }
        let load: PowerAccumulator? = if let sum = telemetryValue("AccumulatedSystemLoad"),
                                         let samples = telemetryValue("SystemLoadAccumulatorCount") {
            PowerAccumulator(sum: sum, samples: samples)
        } else { nil }
        let external = number("ExternalConnected")?.boolValue ?? false
        // Small, and only meaningful while a charger is connected.
        let adapter = external
            ? IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            : nil
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
            onExternalPower: external,
            isCharging: number("IsCharging")?.boolValue ?? false,
            chargePercent: percent,
            currentCapacityMilliampHours: rawCurrent ?? (maximum.map { $0 > 100 } == true ? current : nil),
            fullChargeCapacityMilliampHours: rawMax ?? (maximum.map { $0 > 100 } == true ? maximum : nil),
            designCapacityMilliampHours: number("DesignCapacity")?.doubleValue,
            nominalChargeCapacityMilliampHours: number("NominalChargeCapacity")?.doubleValue,
            voltageMillivolts: number("Voltage")?.doubleValue,
            // int64Value turns the registry's wrapped unsigned value back into a signed one.
            amperageMilliamps: (number("InstantAmperage") ?? number("Amperage")).map { Double($0.int64Value) },
            systemLoadWatts: watts("SystemLoad"),
            batteryDischargeWatts: Self.dischargeWatts(batteryPowerMilliwatts: telemetryValue("BatteryPower")),
            adapterInputWatts: watts("SystemPowerIn"),
            adapterRatedWatts: Self.adapterRating(adapter),
            systemLoadAccumulator: load,
            cycleCount: number("CycleCount")?.intValue,
            temperatureCelsius: temperature.flatMap { (0...90).contains($0) ? $0 : nil },
            readAt: now
        )
    }

    /// BatteryPower is signed, positive into the battery: only a negative
    /// value is power leaving it. A charging figure the telemetry has not yet
    /// replaced after unplugging is not the battery's output.
    static func dischargeWatts(batteryPowerMilliwatts: Double?) -> Double? {
        guard let power = batteryPowerMilliwatts, power < 0 else { return nil }
        return -power / 1_000
    }

    /// The charger's negotiated wattage from AppleSmartBattery's `AdapterDetails`.
    static func adapterRating(_ details: [String: Any]?) -> Double? {
        guard let watts = (details?["Watts"] as? NSNumber)?.doubleValue, watts > 0, watts <= 500 else { return nil }
        return watts
    }
}
