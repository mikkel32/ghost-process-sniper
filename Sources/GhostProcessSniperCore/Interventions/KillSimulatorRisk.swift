import Foundation

/// The launchd of a booted simulated device (`launchd_sim`) is a whole
/// operating system with its apps below it. Stopping it ends them all at
/// once, which is not what Simulator's own shutdown does.
enum KillSimulatorRisk {
    /// What the stop's card, headline and grace are for the device whose
    /// launchd has `commandLine`.
    static func risk(commandLine: String) -> (card: KillRisk, headline: String) {
        guard let id = deviceID(in: commandLine) else {
            return (
                KillRisk(kind: .unsavedWork, severity: .caution, title: title,
                         detail: "\(loseState) Shut it down cleanly from Simulator (Device > Shut Down); xcrun simctl list devices booted shows which one this is."),
                "Stops the simulated device and every app in it at once. Shutting it down from Simulator (Device > Shut Down) is the clean way."
            )
        }
        return (
            KillRisk(kind: .unsavedWork, severity: .caution, title: title,
                     detail: "\(loseState) Shut it down cleanly with xcrun simctl shutdown \(id) or Device > Shut Down in Simulator."),
            "Stops the simulated device and every app in it at once. To shut it down cleanly, run xcrun simctl shutdown \(id)."
        )
    }

    private static let title = "Simulated device stops abruptly"
    private static let loseState = "Apps running in it lose their state at once."

    /// How long a simulated system gets to wind down before force.
    static let graceSeconds: TimeInterval = 6

    /// The device's UDID from the `.../CoreSimulator/Devices/<UDID>/...`
    /// path in launchd_sim's arguments. It ends up in a command the user may
    /// paste, so only a whole, well-formed UDID counts.
    static func deviceID(in commandLine: String) -> String? {
        guard let marker = commandLine.range(of: "/CoreSimulator/Devices/") else { return nil }
        let rest = commandLine[marker.upperBound...]
        let id = rest.prefix(36)
        guard id.count == 36, rest.dropFirst(36).first.map({ $0 == "/" }) ?? true else { return nil }
        for (offset, character) in id.enumerated() {
            let isDash = [8, 13, 18, 23].contains(offset)
            guard isDash ? character == "-" : character.isASCII && character.isHexDigit else { return nil }
        }
        return String(id)
    }
}
