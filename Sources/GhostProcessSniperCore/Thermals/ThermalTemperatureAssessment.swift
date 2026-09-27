import Foundation

/// Product review bands, not vendor operating limits or a hardware-fault detector.
public enum ThermalTemperatureBand: Int, Equatable, Sendable {
    case unavailable, belowReview, warm, hot, veryHot

    public static func classify(_ celsius: Double?) -> Self {
        guard let celsius, celsius.isFinite, celsius > 0, celsius <= 125 else { return .unavailable }
        if celsius >= 90 { return .veryHot }
        if celsius >= 80 { return .hot }
        if celsius >= 70 { return .warm }
        return .belowReview
    }

    public var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .belowReview: "Below warm band"
        case .warm: "Warm"
        case .hot: "Hot"
        case .veryHot: "Very hot"
        }
    }
}

public struct ThermalTemperatureAssessment: Equatable, Sendable {
    public let band: ThermalTemperatureBand
    public let hottestCelsius: Double?
    public let component: String
    public let trajectory: ThermalTrajectory

    public var readingText: String {
        guard let hottestCelsius else { return "Unavailable" }
        return RadarFormat.celsius(hottestCelsius)
    }

    public static func evaluate(snapshot: ThermalSnapshot, observations: ThermalObservationWindow = .init(),
                                at now: Date) -> Self {
        let age = now.timeIntervalSince(snapshot.sampledAt)
        guard age.isFinite, (0...15).contains(age) else { return .unavailable }
        let cpu = valid(snapshot.cpuCelsius)
        let gpu = valid(snapshot.gpuCelsius)
        guard cpu != nil || gpu != nil else { return .unavailable }
        let useCPU = (cpu ?? -.infinity) >= (gpu ?? -.infinity)
        let hottest = useCPU ? cpu : gpu
        return Self(band: .classify(hottest), hottestCelsius: hottest,
                    component: useCPU ? "CPU sensor" : "GPU sensor",
                    trajectory: observations.trajectory(snapshot: snapshot, cpu: useCPU, at: now))
    }

    static func valid(_ value: Double?) -> Double? {
        guard let value, ThermalTemperatureBand.classify(value) != .unavailable else { return nil }
        return value
    }

    private static let unavailable = Self(band: .unavailable, hottestCelsius: nil,
                                          component: "Hardware sensor", trajectory: .empty)
}
