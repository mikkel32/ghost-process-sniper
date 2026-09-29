import CryptoKit
import Foundation

/// What an alert gate remembers between launches: when each thing last
/// alerted, so an update or login does not announce again what the last run
/// already announced. Gate keys hold executable paths and app names, so only
/// their SHA-256 is kept; like the Sentinel trust list, nothing readable is
/// written to the defaults.
public struct AlertMemory: Codable, Equatable, Sendable {
    public var lastAlerted: [String: Date]

    public init(lastAlerted: [String: Date] = [:]) {
        self.lastAlerted = lastAlerted
    }

    public static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The entries still inside `cooldown`. One dated after `now` is dropped
    /// too: a clock that was set wrong must not silence an alert for years.
    func live(cooldown: TimeInterval, at now: Date) -> [String: Date] {
        lastAlerted.filter { (0..<cooldown).contains(now.timeIntervalSince($0.value)) }
    }
}
