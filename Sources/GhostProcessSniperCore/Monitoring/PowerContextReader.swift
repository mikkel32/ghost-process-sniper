import Foundation
import IOKit
#if os(macOS)
import IOKit.ps
#endif

/// How the Mac is powered, which decides how much background sampling is fair.
public struct PowerContext: Equatable, Sendable {
    public let onBattery: Bool
    public let lowPowerMode: Bool

    public static let mains = PowerContext(onBattery: false, lowPowerMode: false)

    public init(onBattery: Bool, lowPowerMode: Bool) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
    }
}

/// Reads the power source at most every 30 s: it changes rarely, and IOPS
/// copies the whole power-source table on every call.
struct PowerContextReader: Sendable {
    static let cacheDuration: TimeInterval = 30

    private let source: @Sendable () -> PowerContext
    private var cached: (context: PowerContext, readAt: Date)?

    init(source: @escaping @Sendable () -> PowerContext = PowerContextReader.systemContext) {
        self.source = source
    }

    mutating func context(now: Date) -> PowerContext {
        if let cached, abs(now.timeIntervalSince(cached.readAt)) < Self.cacheDuration {
            return cached.context
        }
        let context = source()
        cached = (context, now)
        return context
    }

    static func systemContext() -> PowerContext {
        PowerContext(onBattery: isOnBattery(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Desktops have no battery, so a missing power-source table reads as
    /// mains. kIOPSBatteryPowerValue is the same "Battery Power" string as
    /// kIOPMBatteryPowerKey, but lives in IOKit.ps itself.
    private static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return providing as String == kIOPSBatteryPowerValue
    }
}
