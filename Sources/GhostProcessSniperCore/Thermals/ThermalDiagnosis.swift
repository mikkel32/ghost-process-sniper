import Foundation

/// Combines measured heat, its recent trajectory, system pressure and activity
/// without mistaking a review threshold for a hardware-fault diagnosis.
public struct ThermalDiagnosis: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case checking, normal, warm, serious, critical
    }

    /// The platform's pressure state is retained independently of our review bands.
    public let state: State
    /// Compatibility label for the platform signal. Use reviewStatus for the combined headline.
    public let status: String
    public let reviewStatus: String
    public let headline: String
    public let explanation: String
    public let nextStep: String
    public let coverageText: String
    public let isActivityFresh: Bool
    public let temperature: ThermalTemperatureAssessment
    public let pressureText: String

    public static func evaluate(snapshot: ThermalSnapshot, activity: ThermalActivitySummary,
                                observations: ThermalObservationWindow = .init(),
                                pressure: ThermalPressureReading? = nil, at now: Date) -> Self {
        let thermalAge = now.timeIntervalSince(snapshot.sampledAt)
        let temperature = ThermalTemperatureAssessment.evaluate(snapshot: snapshot, observations: observations, at: now)
        let workload = ThermalWorkloadAssessment(activity: activity, at: now)
        let state: State
        if let pressure {
            state = pressure.freshState(at: now)
        } else if !(0...15).contains(thermalAge) {
            state = .checking
        } else {
            // Legacy callers can still supply snapshots without typed pressure.
            switch snapshot.systemState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "nominal", "normal": state = .normal
            case "fair", "elevated": state = .warm
            case "serious": state = .serious
            case "critical": state = .critical
            default: state = .checking
            }
        }

        let status: String
        let headline: String
        let explanation: String
        let pressureText: String
        switch state {
        case .checking: pressureText = "macOS pressure: Unavailable"
        case .normal: pressureText = "macOS pressure: Normal"
        case .warm: pressureText = "macOS pressure: Elevated"
        case .serious: pressureText = "macOS pressure: Serious"
        case .critical: pressureText = "macOS pressure: Critical"
        }
        switch state {
        case .critical:
            status = "Critical pressure"
            headline = "Give your Mac a chance to cool down"
            explanation = "macOS reports critical thermal pressure. Pause optional demanding work and check whether the readings settle."
        case .serious:
            status = "High pressure"
            headline = "Your Mac needs a lighter workload"
            explanation = "macOS reports serious thermal pressure. Review demanding work and pause what can wait."
        case .warm:
            status = "Elevated pressure"
            headline = "Your Mac is experiencing thermal pressure"
            explanation = "macOS reports elevated thermal conditions. Review demanding work even if the readable sensors show a lower temperature."
        case .checking, .normal:
            if temperature.band == .unavailable {
                status = "Checking"
                headline = "Waiting for a current temperature reading"
                explanation = "Without a valid current sensor reading, the dashboard cannot assess the temperature. The macOS pressure report is shown separately."
            } else if temperature.band == .belowReview {
                status = "Below warm band"
                headline = "\(temperature.readingText) at the hottest readable sensor"
                explanation = "The current reading is below the app's 70°C warm-review band. This is a sensor observation, not a complete health check."
            } else {
                let cooling = temperature.trajectory.direction == .falling
                let rising = temperature.trajectory.direction == .rising
                status = cooling ? "Cooling · Still \(temperature.band.label.lowercased())" : temperature.band.label
                if cooling {
                    headline = "Cooling, but still \(temperature.readingText)"
                } else if temperature.band == .veryHot {
                    // Die sensors spike past 90°C for sub-second bursts; only a repeat is actionable.
                    headline = temperature.trajectory.veryHotSeconds > 0
                        ? "\(temperature.readingText) · Reduce optional heavy work"
                        : "\(temperature.readingText) · Brief spike — watching the next readings"
                } else if rising {
                    headline = "\(temperature.readingText) and rising · Review activity"
                } else if temperature.trajectory.hotSeconds >= 60 {
                    headline = "Heat is persisting at \(temperature.readingText)"
                } else {
                    headline = "\(temperature.readingText) · Worth checking"
                }
                let pressure = state == .normal
                    ? "macOS pressure is normal, but that does not make this a cool reading."
                    : "The macOS pressure report is unavailable."
                let activity = workload.isSubstantial
                    ? "A demanding workload is visible; inspect it before deciding whether the heat is unexpected."
                    : "The available activity does not clearly explain this temperature."
                explanation = "\(pressure) \(activity)"
            }
        }
        let nextStep = workload.nextStep(temperature: temperature,
                                         pressureIsHigh: state == .warm || state == .serious || state == .critical)
        let pressureStatus = switch state {
        case .checking: "Checking"
        case .normal: "Normal pressure"
        case .warm: "Elevated pressure"
        case .serious: "High pressure"
        case .critical: "Critical pressure"
        }
        return Self(state: state, status: pressureStatus, reviewStatus: status, headline: headline, explanation: explanation,
                    nextStep: nextStep, coverageText: workload.coverageText, isActivityFresh: workload.isFresh,
                    temperature: temperature, pressureText: pressureText)
    }
}
