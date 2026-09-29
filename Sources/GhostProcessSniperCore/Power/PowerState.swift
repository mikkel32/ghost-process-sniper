import Foundation

/// What the battery is really doing, from which way current flows through it.
/// The IsCharging flag says whether macOS is trying to charge; on a charger
/// too small for the work it stays on while the battery drains.
public enum PowerState: Equatable, Sendable {
    case onBattery
    /// On power, and current flows into the battery.
    case charging
    /// On power, and the battery is neither gaining nor losing: full, held at a charge limit, or paused.
    case pluggedIn
    /// On power, but the Mac wants more than the charger gives, so the battery covers the rest.
    case drainingOnPower

    // Watts of net battery flow, positive into the battery. Each state is entered further from zero
    // than it is left, so a flow hovering at a threshold does not flip the header every scan.
    static let chargingEnter = 0.5
    static let chargingStay = 0.2
    static let drainEnter = -1.5
    static let drainStay = -0.5
    /// A drain only counts while the wall delivers about what the charger is rated for.
    static let chargerSaturation = 0.8
}

extension BatteryReading {
    /// `previous` is the state of the last reading, for the hysteresis; nil without a battery.
    public func powerState(after previous: PowerState?) -> PowerState? {
        guard hasBattery else { return nil }
        guard onExternalPower else { return .onBattery }
        // Without a current there is only the flag to go on.
        guard let flow = netBatteryWatts else { return isCharging ? .charging : .pluggedIn }
        if flow >= (previous == .charging ? PowerState.chargingStay : PowerState.chargingEnter) { return .charging }
        if flow <= (previous == .drainingOnPower ? PowerState.drainStay : PowerState.drainEnter) {
            if chargerIsDelivering { return .drainingOnPower }
            // The telemetry lags the flag by seconds: a drain the wall input does not back is what
            // the battery was doing before the charger went in.
            return isCharging ? .charging : .pluggedIn
        }
        return .pluggedIn
    }

    private var chargerIsDelivering: Bool {
        guard let input = adapterInputWatts, let rated = adapterRatedWatts, rated > 0 else { return true }
        return input >= rated * PowerState.chargerSaturation
    }
}
