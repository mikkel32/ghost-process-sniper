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

    /// The display label snapshots have always carried for the platform signal.
    var systemStateLabel: String {
        switch state {
        case .normal: "Nominal"
        case .warm: "Elevated"
        case .serious: "Serious"
        case .critical: "Critical"
        case .checking: "Unknown"
        }
    }

    /// What the menu-bar popover says when macOS itself is holding the Mac back.
    public struct Throttling: Equatable, Sendable {
        public let label: String
        /// The fuller sentence, for a tooltip.
        public let detail: String
        public let isCritical: Bool
    }

    /// Only Serious and Critical count: Fair is common under ordinary load.
    /// A stale or future reading says nothing about now, so it is not shown.
    public func throttling(at now: Date) -> Throttling? {
        switch freshState(at: now) {
        case .serious:
            Throttling(label: "Throttling",
                       detail: "macOS reports serious thermal pressure and may slow the Mac down to cool it.",
                       isCritical: false)
        case .critical:
            Throttling(label: "Critical heat",
                       detail: "macOS reports critical thermal pressure. Pause optional demanding work and let the Mac cool.",
                       isCritical: true)
        case .normal, .warm, .checking:
            nil
        }
    }

    func freshState(at now: Date) -> ThermalDiagnosis.State {
        (0...15).contains(now.timeIntervalSince(sampledAt)) ? state : .checking
    }
}
