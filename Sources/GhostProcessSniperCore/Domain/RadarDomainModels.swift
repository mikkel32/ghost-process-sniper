import Foundation

public struct RadarSummary: Equatable, Sendable {
    public let statusText: String
    public let level: GhostLevel
    public let familyCount: Int
    public let hotCount: Int
    public let totalMemoryBytes: UInt64
    public let topFamilyName: String?
    public let leakingCount: Int
    public let suggestionCount: Int
    /// When host memory pressure turns critical at the current growth.
    public let hostPressureETA: TimeInterval?
    /// The family driving that growth the most.
    public let hostPressureCulprit: String?

    public static let empty = RadarSummary(
        statusText: "Quiet",
        level: .quiet,
        familyCount: 0,
        hotCount: 0,
        totalMemoryBytes: 0,
        topFamilyName: nil,
        leakingCount: 0,
        suggestionCount: 0
    )

    public init(
        statusText: String,
        level: GhostLevel,
        familyCount: Int,
        hotCount: Int,
        totalMemoryBytes: UInt64,
        topFamilyName: String?,
        leakingCount: Int = 0,
        suggestionCount: Int = 0,
        hostPressureETA: TimeInterval? = nil,
        hostPressureCulprit: String? = nil
    ) {
        self.statusText = statusText
        self.level = level
        self.familyCount = familyCount
        self.hotCount = hotCount
        self.totalMemoryBytes = totalMemoryBytes
        self.topFamilyName = topFamilyName
        self.leakingCount = leakingCount
        self.suggestionCount = suggestionCount
        self.hostPressureETA = hostPressureETA
        self.hostPressureCulprit = hostPressureCulprit
    }
}

public enum RadarActionType: String, Codable, CaseIterable, Sendable {
    case notify
    case highlight
    case snooze
    case ignore
    case inspect
    case suggestKill
    case kill

    public var label: String {
        switch self {
        case .notify: "Notify"
        case .highlight: "Highlight"
        case .snooze: "Snooze"
        case .ignore: "Ignore"
        case .inspect: "Inspect"
        case .suggestKill: "Suggest Kill"
        case .kill: "Kill"
        }
    }
}

public struct RadarActionSuggestion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let type: RadarActionType
    public let title: String
    public let detail: String
    public let ruleID: UUID?
    public let createdAt: Date
    /// The processes the action is about when they are not the family
    /// itself, e.g. the redundant copies of a duplicated server. Stop the
    /// family that owns each one.
    public let targetIdentities: [ProcessIdentity]?

    /// Without an explicit `id`, the same rule (or the forecast) and action
    /// always get the same id, so a suggestion card keeps its identity
    /// across refreshes.
    public init(
        id: UUID? = nil,
        type: RadarActionType,
        title: String,
        detail: String,
        ruleID: UUID? = nil,
        createdAt: Date = Date(),
        targetIdentities: [ProcessIdentity]? = nil
    ) {
        self.id = id ?? Self.stableID(ruleID: ruleID, type: type)
        self.type = type
        self.title = title
        self.detail = detail
        self.ruleID = ruleID
        self.createdAt = createdAt
        self.targetIdentities = targetIdentities
    }

    public static func stableID(ruleID: UUID?, type: RadarActionType) -> UUID {
        stableID(scope: ruleID?.uuidString ?? "forecast", type: type)
    }

    /// A stable id for a suggestion that no rule owns, e.g. "duplicate|<key>".
    public static func stableID(scope: String, type: RadarActionType) -> UUID {
        let key = Array("\(scope)|\(type.rawValue)".utf8)
        let basis: UInt64 = 0xcbf2_9ce4_8422_2325
        let high = fnv1a(key, seed: basis)
        let low = fnv1a(key, seed: basis ^ 1)
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: high >> (56 - 8 * $0)) } +
            (0..<8).map { UInt8(truncatingIfNeeded: low >> (56 - 8 * $0)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8: custom
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func fnv1a(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
        bytes.reduce(seed) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}



public enum AlertStateKind: String, Codable, Sendable {
    case normal
    case new
    case recurring
    case snoozed
    case ignored
}

public struct AlertState: Codable, Equatable, Sendable {
    public let kind: AlertStateKind
    public let message: String
    public let since: Date

    public static let normal = AlertState(kind: .normal, message: "Normal", since: Date(timeIntervalSince1970: 0))

    public init(kind: AlertStateKind, message: String, since: Date) {
        self.kind = kind
        self.message = message
        self.since = since
    }
}



public struct RadarRuleMatch: Codable, Hashable, Sendable {
    public var signatureID: String?
    public var commandContains: String?
    public var pathContains: String?
    public var minimumLevel: GhostLevel
    public var minimumScore: Double
    public var minimumLeakVelocity: Double?
    public var minimumAgeMinutes: Double?
    public var minimumIncidentCount: Int?

    public init(
        signatureID: String? = nil,
        commandContains: String? = nil,
        pathContains: String? = nil,
        minimumLevel: GhostLevel = .watch,
        minimumScore: Double = 0,
        minimumLeakVelocity: Double? = nil,
        minimumAgeMinutes: Double? = nil,
        minimumIncidentCount: Int? = nil
    ) {
        self.signatureID = signatureID
        self.commandContains = commandContains
        self.pathContains = pathContains
        self.minimumLevel = minimumLevel
        self.minimumScore = minimumScore
        self.minimumLeakVelocity = minimumLeakVelocity
        self.minimumAgeMinutes = minimumAgeMinutes
        self.minimumIncidentCount = minimumIncidentCount
    }
}

public struct RadarRule: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var match: RadarRuleMatch
    public var action: RadarActionType
    public var expiresAt: Date?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        match: RadarRuleMatch,
        action: RadarActionType,
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.match = match
        self.action = action
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    public static func builtIns(settings: ThresholdSettings) -> [RadarRule] {
        [
            RadarRule(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "Critical families need attention",
                isBuiltIn: true,
                match: RadarRuleMatch(minimumLevel: .critical, minimumScore: 70),
                action: .notify
            ),
            RadarRule(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Fast leaks should be inspected",
                isBuiltIn: true,
                match: RadarRuleMatch(
                    minimumLevel: .watch,
                    minimumScore: 35,
                    minimumLeakVelocity: settings.leakVelocityMegabytesPerMinute
                ),
                action: .inspect
            ),
            RadarRule(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                name: "Hot killable trees get a kill suggestion",
                isBuiltIn: true,
                match: RadarRuleMatch(minimumLevel: .hot, minimumScore: 55),
                action: .suggestKill
            )
        ]
    }
}

public struct RadarIncident: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let signature: ProcessSignature
    public var familyName: String
    public var level: GhostLevel
    public var maxScore: Double
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    public var leakVelocityMegabytesPerMinute: Double
    public var reasons: [String]
    public var startedAt: Date
    public var lastSeenAt: Date
    public var resolvedAt: Date?
    public var occurrenceCount: Int

    public init(
        id: UUID = UUID(),
        signature: ProcessSignature,
        familyName: String,
        level: GhostLevel,
        maxScore: Double,
        memoryBytes: UInt64,
        cpuPercent: Double,
        leakVelocityMegabytesPerMinute: Double,
        reasons: [String],
        startedAt: Date,
        lastSeenAt: Date,
        resolvedAt: Date? = nil,
        occurrenceCount: Int = 1
    ) {
        self.id = id
        self.signature = signature
        self.familyName = familyName
        self.level = level
        self.maxScore = maxScore
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.leakVelocityMegabytesPerMinute = leakVelocityMegabytesPerMinute
        self.reasons = reasons
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
        self.resolvedAt = resolvedAt
        self.occurrenceCount = occurrenceCount
    }
}

public struct RadarContext: Equatable, Sendable {
    public let baselines: [String: FamilyBaseline]
    public let recentIncidentCounts: [String: Int]
    public let rules: [RadarRule]
    public let systemPressure: SystemMemoryPressure
    /// Each family's share of host memory pressure, by family key.
    public let pressureShares: [String: PressureShare]
    public let hostOutlook: HostMemoryOutlook?

    public init(
        baselines: [String: FamilyBaseline],
        recentIncidentCounts: [String: Int],
        rules: [RadarRule],
        systemPressure: SystemMemoryPressure = .unknown,
        pressureShares: [String: PressureShare] = [:],
        hostOutlook: HostMemoryOutlook? = nil
    ) {
        self.baselines = baselines
        self.recentIncidentCounts = recentIncidentCounts
        self.rules = rules
        self.systemPressure = systemPressure
        self.pressureShares = pressureShares
        self.hostOutlook = hostOutlook
    }

    public func updating(systemPressure: SystemMemoryPressure) -> RadarContext {
        RadarContext(
            baselines: baselines,
            recentIncidentCounts: recentIncidentCounts,
            rules: rules,
            systemPressure: systemPressure,
            pressureShares: pressureShares,
            hostOutlook: hostOutlook
        )
    }

    /// Attributes host pressure across this tick's families.
    public func attributingPressure(to families: [ProcessFamily]) -> RadarContext {
        guard systemPressure.isKnown, systemPressure.level >= .elevated else { return self }
        return RadarContext(
            baselines: baselines,
            recentIncidentCounts: recentIncidentCounts,
            rules: rules,
            systemPressure: systemPressure,
            pressureShares: PressureAttribution.compute(families: families, pressure: systemPressure),
            hostOutlook: PressureAttribution.outlook(families: families, pressure: systemPressure)
        )
    }

    /// This family's share, computed alone when the tick had none.
    public func pressureShare(for family: ProcessFamily) -> PressureShare {
        pressureShares[family.familyKey] ?? PressureAttribution.share(for: family, pressure: systemPressure)
    }
}

public struct RadarModel: Equatable, Sendable {
    public let families: [ProcessFamily]
    public let duplicateClusters: [DuplicateProcessCluster]
    public let summary: RadarSummary
    public let incidents: [RadarIncident]
    public let rules: [RadarRule]
    public let health: SamplerHealth
    public let generatedAt: Date

    public init(
        families: [ProcessFamily],
        duplicateClusters: [DuplicateProcessCluster] = [],
        summary: RadarSummary,
        incidents: [RadarIncident],
        rules: [RadarRule],
        health: SamplerHealth,
        generatedAt: Date
    ) {
        self.families = families
        self.duplicateClusters = duplicateClusters
        self.summary = summary
        self.incidents = incidents
        self.rules = rules
        self.health = health
        self.generatedAt = generatedAt
    }

    public static let empty = RadarModel(
        families: [],
        duplicateClusters: [],
        summary: .empty,
        incidents: [],
        rules: [],
        health: .starting,
        generatedAt: Date(timeIntervalSince1970: 0)
    )
}

public protocol RadarNotifying: Sendable {
    func process(model: RadarModel) async
}

public struct NoopRadarNotifier: RadarNotifying {
    public init() {}
    public func process(model: RadarModel) async {}
}
