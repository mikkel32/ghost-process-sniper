import Darwin
import Foundation

public struct KillEscalationProfile: Equatable, Sendable {
    public let gracefulSignal: Int32
    public let forcedSignal: Int32
    public let forceKillDelay: TimeInterval

    public static func `default`(
        gracefulSignal: Int32 = SIGTERM,
        forceKillDelay: TimeInterval = 2
    ) -> KillEscalationProfile {
        KillEscalationProfile(
            gracefulSignal: gracefulSignal,
            forcedSignal: SIGKILL,
            forceKillDelay: forceKillDelay
        )
    }

    public init(gracefulSignal: Int32, forcedSignal: Int32, forceKillDelay: TimeInterval) {
        self.gracefulSignal = gracefulSignal
        self.forcedSignal = forcedSignal
        self.forceKillDelay = max(0, forceKillDelay)
    }
}

public enum KillStrategy: String, Codable, CaseIterable, Sendable {
    case standard
    case gentleDevServer
    case stubbornRunaway
    /// Ask a GUI app to quit like ⌘Q, so it can save and close its helpers.
    case quitApp
    /// Databases and container runtimes: SIGTERM with time to flush data.
    case carefulShutdown
    case inspectOnly

    public var label: String {
        switch self {
        case .standard: "Standard"
        case .gentleDevServer: "Gentle dev server"
        case .stubbornRunaway: "Stubborn runaway"
        case .quitApp: "Quit app"
        case .carefulShutdown: "Careful shutdown"
        case .inspectOnly: "Inspect only"
        }
    }

    public func signals(gracefulSignal: Int32 = SIGTERM) -> [Int32] {
        switch self {
        case .standard:
            return [gracefulSignal, SIGKILL]
        case .gentleDevServer:
            return [SIGINT, SIGTERM, SIGKILL]
        case .quitApp:
            return [KillSignalPhase.quitRequest, SIGTERM, SIGKILL]
        case .stubbornRunaway, .carefulShutdown:
            return [SIGTERM, SIGKILL]
        case .inspectOnly:
            return []
        }
    }

    /// Strategies that try a second, still-polite step before any force.
    var hasSecondaryStep: Bool { self == .gentleDevServer || self == .quitApp }
}

public enum KillDecisionFactorKind: String, Codable, Sendable {
    case whyKill
    case whyWait
    case blocking
}

public struct KillDecisionFactor: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)-\(title)-\(Int(weight.rounded()))" }

    public let kind: KillDecisionFactorKind
    public let title: String
    public let detail: String
    public let weight: Double

    public init(kind: KillDecisionFactorKind, title: String, detail: String, weight: Double) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.weight = weight
    }
}

public struct KillDecisionScore: Codable, Equatable, Sendable {
    public let value: Double
    public let confidence: Double
    public let factors: [KillDecisionFactor]

    public static let empty = KillDecisionScore(value: 0, confidence: 0, factors: [])

    public init(value: Double, confidence: Double, factors: [KillDecisionFactor]) {
        self.value = min(100, max(0, value))
        self.confidence = min(1, max(0, confidence))
        self.factors = factors
    }

    public var whyKill: [KillDecisionFactor] {
        factors.filter { $0.kind == .whyKill }
    }

    public var whyWait: [KillDecisionFactor] {
        factors.filter { $0.kind == .whyWait || $0.kind == .blocking }
    }
}

public struct KillSignalPhase: Identifiable, Codable, Equatable, Sendable {
    /// Not a signal: a polite quit request, like choosing Quit from the app's menu.
    public static let quitRequest: Int32 = 0

    public var id: String { "\(order)-\(signalName)-\(label)" }

    public let order: Int
    public let label: String
    public let signal: Int32?
    public let waitAfterSeconds: TimeInterval
    public let isForce: Bool

    public var signalName: String {
        guard let signal else {
            return "VERIFY"
        }
        return switch signal {
        case Self.quitRequest: "QUIT"
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        default: "SIG\(signal)"
        }
    }

    public init(order: Int, label: String, signal: Int32?, waitAfterSeconds: TimeInterval, isForce: Bool) {
        self.order = order
        self.label = label
        self.signal = signal
        self.waitAfterSeconds = max(0, waitAfterSeconds)
        self.isForce = isForce
    }
}

public struct KillVerificationSchedule: Codable, Equatable, Sendable {
    public let graceSeconds: TimeInterval
    public let secondaryGraceSeconds: TimeInterval
    public let settleSeconds: TimeInterval
    public let allowsSkipForce: Bool

    public static let standard = KillVerificationSchedule(
        graceSeconds: 2,
        secondaryGraceSeconds: 0.15,
        settleSeconds: 0.35,
        allowsSkipForce: true
    )

    public init(
        graceSeconds: TimeInterval,
        secondaryGraceSeconds: TimeInterval,
        settleSeconds: TimeInterval,
        allowsSkipForce: Bool
    ) {
        self.graceSeconds = max(0, graceSeconds)
        self.secondaryGraceSeconds = max(0, secondaryGraceSeconds)
        self.settleSeconds = max(0, settleSeconds)
        self.allowsSkipForce = allowsSkipForce
    }
}

public struct KillStrategyProfile: Codable, Equatable, Sendable {
    public let strategy: KillStrategy
    public let confidence: Double
    public let phases: [KillSignalPhase]
    public let verificationSchedule: KillVerificationSchedule
    public let summary: String

    public static let standard = KillStrategyProfile(
        strategy: .standard,
        confidence: 0.65,
        phases: [
            KillSignalPhase(order: 0, label: "Ask target to terminate", signal: SIGTERM, waitAfterSeconds: 2, isForce: false),
            KillSignalPhase(order: 1, label: "Force same-identity survivors", signal: SIGKILL, waitAfterSeconds: 0.35, isForce: true)
        ],
        verificationSchedule: .standard,
        summary: "SIGTERM, verify, then SIGKILL same-identity survivors."
    )

    public init(
        strategy: KillStrategy,
        confidence: Double,
        phases: [KillSignalPhase],
        verificationSchedule: KillVerificationSchedule,
        summary: String
    ) {
        self.strategy = strategy
        self.confidence = min(1, max(0, confidence))
        self.phases = phases
        self.verificationSchedule = verificationSchedule
        self.summary = summary
    }
}

public struct KillStrategyRecommendation: Codable, Equatable, Sendable {
    public let strategy: KillStrategy
    public let confidence: Double
    public let reasons: [String]
    public let previewText: String

    public static let standard = KillStrategyRecommendation(
        strategy: .standard,
        confidence: 0.65,
        reasons: ["Default safe intervention profile."],
        previewText: "SIGTERM, verify, then SIGKILL surviving same-identity targets."
    )

    public init(strategy: KillStrategy, confidence: Double, reasons: [String], previewText: String) {
        self.strategy = strategy
        self.confidence = min(1, max(0, confidence))
        self.reasons = reasons
        self.previewText = previewText
    }
}

public enum KillReadiness: String, Codable, Comparable, Sendable {
    case ready
    case caution
    case locked

    public static func < (lhs: KillReadiness, rhs: KillReadiness) -> Bool {
        order(lhs) < order(rhs)
    }

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .caution: "Caution"
        case .locked: "Locked"
        }
    }

    private static func order(_ readiness: KillReadiness) -> Int {
        switch readiness {
        case .locked: 0
        case .caution: 1
        case .ready: 2
        }
    }
}

public enum KillDecisionEvidenceKind: String, Codable, Sendable {
    case positive
    case caution
    case blocking
    case info
}

public struct KillDecisionEvidence: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)-\(title)-\(detail)" }

    public let kind: KillDecisionEvidenceKind
    public let title: String
    public let detail: String

    public init(kind: KillDecisionEvidenceKind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct KillConfidenceModel: Sendable {
    public init() {}

    public func evidence(
        plan: KillPlan,
        targets: [KillTarget],
        locked: [KillTarget],
        stale: [KillTarget],
        recycled: [KillTarget],
        reclaim: KillReclaimEstimate
    ) -> [KillDecisionEvidence] {
        var output: [KillDecisionEvidence] = []
        if targets.isEmpty {
            output.append(
                KillDecisionEvidence(
                    kind: .blocking,
                    title: "No owned live targets",
                    detail: "The selected identity tree has no same-user process to signal."
                )
            )
        } else {
            output.append(
                KillDecisionEvidence(
                    kind: .positive,
                    title: "Identity verified",
                    detail: "\(targets.count) owned target\(targets.count == 1 ? "" : "s") matched by PID plus start time."
                )
            )
            output.append(
                KillDecisionEvidence(
                    kind: .positive,
                    title: "Estimated reclaim",
                    detail: "\(RadarFormat.bytes(reclaim.memoryBytes)) and \(Int(reclaim.cpuPercent.rounded()))% CPU from \(reclaim.sourceText.lowercased())."
                )
            )
        }

        if !locked.isEmpty {
            output.append(
                KillDecisionEvidence(
                    kind: .caution,
                    title: "Locked descendants",
                    detail: "\(locked.count) protected or foreign process\(locked.count == 1 ? "" : "es") will stay untouched."
                )
            )
        }
        if !stale.isEmpty || !recycled.isEmpty {
            output.append(
                KillDecisionEvidence(
                    kind: .caution,
                    title: "Tree changed",
                    detail: "\(stale.count) stale and \(recycled.count) recycled PID\(stale.count + recycled.count == 1 ? "" : "s") were excluded."
                )
            )
        }
        if let metadata = plan.familyMetadata {
            if metadata.scoreLevel >= .hot || metadata.forecastState >= .leaking {
                output.append(
                    KillDecisionEvidence(
                        kind: .positive,
                        title: "High-risk family",
                        detail: "\(metadata.devKindLabel) is \(metadata.scoreLevel.label.lowercased()) with forecast \(metadata.forecastState.label.lowercased())."
                    )
                )
            }
            if metadata.isBackgroundOrOrphan {
                output.append(
                    KillDecisionEvidence(
                        kind: .positive,
                        title: "Background candidate",
                        detail: "The root appears orphaned or backgrounded, which raises kill confidence."
                    )
                )
            }
            if metadata.devKindLabel.localizedCaseInsensitiveContains("build") && metadata.scoreLevel < .critical {
                output.append(
                    KillDecisionEvidence(
                        kind: .caution,
                        title: "Active build caution",
                        detail: "This looks like a build tool; inspect before interrupting unless it is stale."
                    )
                )
            }
        }
        return output
    }
}

public struct KillSafetyGate: Sendable {
    public init() {}

    public func readiness(hasTargets: Bool, evidence: [KillDecisionEvidence]) -> KillReadiness {
        guard hasTargets else {
            return .locked
        }
        if evidence.contains(where: { $0.kind == .blocking }) {
            return .locked
        }
        if evidence.contains(where: { $0.kind == .caution }) {
            return .caution
        }
        return .ready
    }
}
