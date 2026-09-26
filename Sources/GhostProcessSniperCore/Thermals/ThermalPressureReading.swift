import Foundation

/// Typed platform evidence is independent of SMC sensor availability and of
/// human-readable strings retained by older snapshots.
public struct ThermalPressureReading: Equatable, Sendable {
    public let state: ThermalDiagnosis.State
    public let sampledAt: Date

    public init(state: ThermalDiagnosis.State, sampledAt: Date) {
        self.state = state
        self.sampledAt = sampledAt
    }

    public static func current(at now: Date = Date()) -> Self {
        let state: ThermalDiagnosis.State = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .normal
        case .fair: .warm
        case .serious: .serious
        case .critical: .critical
        @unknown default: .checking
        }
        return Self(state: state, sampledAt: now)
    }

    func freshState(at now: Date) -> ThermalDiagnosis.State {
        (0...15).contains(now.timeIntervalSince(sampledAt)) ? state : .checking
    }
}
