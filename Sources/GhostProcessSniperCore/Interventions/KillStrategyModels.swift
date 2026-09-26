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

/// What a phase does to its targets.
public enum KillPhaseAction: Codable, Equatable, Sendable {
    /// Not a signal: a polite quit request, like choosing Quit from the app's menu.
    case quitRequest
    case signal(Int32)

    public var name: String {
        switch self {
        case .quitRequest: "QUIT"
        case .signal(SIGINT): "SIGINT"
        case .signal(SIGTERM): "SIGTERM"
        case .signal(SIGKILL): "SIGKILL"
        case .signal(SIGSTOP): "SIGSTOP"
        case .signal(SIGCONT): "SIGCONT"
        case .signal(let signal): "SIG\(signal)"
        }
    }
}

/// Who a phase's signal goes to.
public enum KillSignalReach: String, Codable, Sendable {
    /// Every target still running, deepest first.
    case tree
    /// Only the root, which stops its own workers in order; targets outside
    /// its tree still get the signal.
    case rootOnly
}

public struct KillSignalPhase: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(order)-\(signalName)-\(label)" }

    public let order: Int
    public let label: String
    public let action: KillPhaseAction
    /// The longest wait for the targets to exit before the next phase.
    public let waitAfterSeconds: TimeInterval
    public let reach: KillSignalReach

    public var signalName: String { action.name }
    /// Force cannot be caught or answered; it is the step a hold stops before.
    public var isForce: Bool { action == .signal(SIGKILL) }

    public init(order: Int, label: String, action: KillPhaseAction, waitAfterSeconds: TimeInterval, reach: KillSignalReach = .tree) {
        self.order = order
        self.label = label
        self.action = action
        self.waitAfterSeconds = max(0, waitAfterSeconds)
        self.reach = reach
    }

    /// The same step with a different wait.
    func waiting(_ seconds: TimeInterval) -> KillSignalPhase {
        KillSignalPhase(order: order, label: label, action: action, waitAfterSeconds: seconds, reach: reach)
    }
}

/// The phases a stop runs, in order. Approved in the preview, then run as-is.
public struct KillStrategyProfile: Codable, Equatable, Sendable {
    public let strategy: KillStrategy
    public let confidence: Double
    public let phases: [KillSignalPhase]
    public let summary: String

    public static let standard = KillStrategyProfile(
        strategy: .standard,
        confidence: 0.65,
        phases: [
            KillSignalPhase(order: 0, label: "Ask target to terminate", action: .signal(SIGTERM), waitAfterSeconds: 2),
            KillSignalPhase(order: 1, label: "Force same-identity survivors", action: .signal(SIGKILL), waitAfterSeconds: 0.35)
        ],
        summary: "SIGTERM, verify, then SIGKILL same-identity survivors."
    )

    /// For survivors the user chose to force after a held stop: nothing
    /// polite is repeated.
    public static let forceNow = KillStrategyProfile(
        strategy: .stubbornRunaway,
        confidence: 1,
        phases: [
            KillSignalPhase(order: 0, label: "Force the processes still running", action: .signal(SIGKILL), waitAfterSeconds: 0.35)
        ],
        summary: "SIGKILL the verified survivors now."
    )

    public init(strategy: KillStrategy, confidence: Double, phases: [KillSignalPhase], summary: String) {
        self.strategy = strategy
        self.confidence = min(1, max(0, confidence))
        self.phases = phases
        self.summary = summary
    }

    /// How long the first, graceful step waits for a clean exit.
    public var graceSeconds: TimeInterval { phases.first?.waitAfterSeconds ?? 0 }

    /// The wait after a polite follow-up such as SIGTERM after SIGINT.
    public var secondaryGraceSeconds: TimeInterval {
        phases.dropFirst().first { !$0.isForce }?.waitAfterSeconds ?? 0
    }

    /// The settle time after force.
    public var settleSeconds: TimeInterval { phases.last { $0.isForce }?.waitAfterSeconds ?? 0 }

    /// The same phases with the first wait raised to at least `seconds`.
    func extendingGrace(to seconds: TimeInterval) -> KillStrategyProfile {
        guard let first = phases.first, !first.isForce, seconds > first.waitAfterSeconds else { return self }
        return KillStrategyProfile(strategy: strategy, confidence: confidence, phases: [first.waiting(seconds)] + phases.dropFirst(), summary: summary)
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
