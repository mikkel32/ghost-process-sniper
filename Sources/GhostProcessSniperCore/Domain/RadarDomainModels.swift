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
        suggestionCount: Int = 0
    ) {
        self.statusText = statusText
        self.level = level
        self.familyCount = familyCount
        self.hotCount = hotCount
        self.totalMemoryBytes = totalMemoryBytes
        self.topFamilyName = topFamilyName
        self.leakingCount = leakingCount
        self.suggestionCount = suggestionCount
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

    public init(
        id: UUID = UUID(),
        type: RadarActionType,
        title: String,
        detail: String,
        ruleID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.detail = detail
        self.ruleID = ruleID
        self.createdAt = createdAt
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



public struct RadarRuleMatch: Codable, Equatable, Sendable {
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

    public init(
        baselines: [String: FamilyBaseline],
        recentIncidentCounts: [String: Int],
        rules: [RadarRule],
        systemPressure: SystemMemoryPressure = .unknown
    ) {
        self.baselines = baselines
        self.recentIncidentCounts = recentIncidentCounts
        self.rules = rules
        self.systemPressure = systemPressure
    }

    public func updating(systemPressure: SystemMemoryPressure) -> RadarContext {
        RadarContext(
            baselines: baselines,
            recentIncidentCounts: recentIncidentCounts,
            rules: rules,
            systemPressure: systemPressure
        )
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
