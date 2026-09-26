import Darwin
import Foundation

/// Both libproc CPU counters use Mach absolute-time units, including TASKINFO.
/// On Apple silicon a tick is not a nanosecond. Convert before taking CPU deltas.
enum ProcessCPUTime {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        guard mach_timebase_info(&value) == KERN_SUCCESS else { return .init() }
        return value
    }()

    static func seconds(user: UInt64, system: UInt64) -> TimeInterval {
        seconds(user: user, system: system, numerator: timebase.numer, denominator: timebase.denom)
    }

    static func seconds(user: UInt64, system: UInt64, numerator: UInt32,
                        denominator: UInt32) -> TimeInterval {
        guard numerator > 0, denominator > 0 else { return .nan }
        // Convert each counter before addition to avoid integer overflow.
        return (Double(user) + Double(system)) * (Double(numerator) / Double(denominator)) / 1_000_000_000
    }
}
