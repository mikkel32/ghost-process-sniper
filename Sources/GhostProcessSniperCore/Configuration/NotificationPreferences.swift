import Foundation

/// How much of what the Sentinel finds may raise a system notification.
/// There is deliberately no "off": a dangerous finding always notifies.
public enum SecurityAlertLevel: String, Codable, CaseIterable, Sendable {
    case suspiciousAndDangerous
    case dangerousOnly

    public var label: String {
        switch self {
        case .suspiciousAndDangerous: "Suspicious and dangerous"
        case .dangerousOnly: "Dangerous only"
        }
    }
}

/// Which kinds of alert may notify. macOS has one switch for the whole app,
/// so without this the only way to quiet Security or Energy is to lose the
/// process alerts too. Everything defaults to today's behavior, and this
/// only decides who may *notify*: the Security page, the menu-bar icon and
/// the console show everything either way.
public struct NotificationPreferences: Codable, Equatable, Sendable {
    /// Process alerts: a family that is Hot or Critical.
    public var families: Bool
    public var energy: Bool
    public var security: SecurityAlertLevel

    public init(families: Bool = true, energy: Bool = true, security: SecurityAlertLevel = .suspiciousAndDangerous) {
        self.families = families
        self.energy = energy
        self.security = security
    }

    /// Reads each choice on its own: a value this version does not know (one
    /// written by a later release) falls back to its default, and never costs
    /// the store the rest of the settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        families = (try? container.decodeIfPresent(Bool.self, forKey: .families)) ?? true
        energy = (try? container.decodeIfPresent(Bool.self, forKey: .energy)) ?? true
        security = (try? container.decodeIfPresent(SecurityAlertLevel.self, forKey: .security)) ?? .suspiciousAndDangerous
    }
}
