import Foundation

/// The one-click stop offered wherever a culprit appears. It names what the
/// stop will really do (quit an app, shut a database down, stop a server)
/// and, when a supervisor such as nodemon restarts the family, targets the
/// supervisor instead. It only opens the stop preview; nothing runs without
/// the user's confirmation there.
public struct QuickStopAction: Equatable, Sendable {
    public enum Emphasis: Sendable {
        case recommended, available, unavailable
    }

    /// The row this action is shown on.
    public let familyKey: String
    /// The family the preview is prepared for: the supervisor after a redirect.
    public let targetFamilyKey: String
    public let displayName: String
    public let title: String
    public let shortTitle: String
    public let detail: String?
    public let systemImage: String
    public let emphasis: Emphasis
    /// Set when the target is a supervisor: the family it keeps restarting.
    public let redirectedFromName: String?

    public init(
        familyKey: String,
        targetFamilyKey: String,
        displayName: String,
        title: String,
        shortTitle: String,
        detail: String?,
        systemImage: String,
        emphasis: Emphasis,
        redirectedFromName: String? = nil
    ) {
        self.familyKey = familyKey
        self.targetFamilyKey = targetFamilyKey
        self.displayName = displayName
        self.title = title
        self.shortTitle = shortTitle
        self.detail = detail
        self.systemImage = systemImage
        self.emphasis = emphasis
        self.redirectedFromName = redirectedFromName
    }

    public var isAvailable: Bool { emphasis != .unavailable }

    /// - Parameter supervisorFamilyKey: the tracked family you own that
    ///   contains the supervisor's PID, when there is one.
    public static func make(
        familyKey: String,
        displayName: String,
        level: GhostLevel,
        heatConfirmed: Bool,
        hasOwnedTargets: Bool,
        risk: KillRiskAssessment,
        supervisorFamilyKey: String? = nil,
        appName: String? = nil
    ) -> QuickStopAction {
        guard hasOwnedTargets else {
            return QuickStopAction(
                familyKey: familyKey, targetFamilyKey: familyKey, displayName: displayName,
                title: "Stop \(displayName)…", shortTitle: "Stop…",
                detail: "None of its processes are yours to stop", systemImage: "lock", emphasis: .unavailable
            )
        }
        // A stop that could lose data is offered, never pushed.
        let isSafe = (risk.highestSeverity ?? .info) < .danger
        let emphasis: Emphasis = level >= .hot && heatConfirmed && isSafe ? .recommended : .available

        if let supervisor = risk.supervisor, supervisor.pid != nil,
           let supervisorFamilyKey, supervisorFamilyKey != familyKey {
            return QuickStopAction(
                familyKey: familyKey, targetFamilyKey: supervisorFamilyKey, displayName: displayName,
                title: "Stop \(supervisor.name)…", shortTitle: "Stop \(supervisor.name)…",
                detail: "\(displayName) is restarted by \(supervisor.name)",
                systemImage: "arrow.triangle.2.circlepath", emphasis: emphasis, redirectedFromName: displayName
            )
        }

        let restartNote = risk.supervisor.map { "\($0.name) may restart it" }
        func action(_ title: String, _ shortTitle: String, _ image: String, _ detail: String? = nil) -> QuickStopAction {
            let details = [detail, restartNote].compactMap { $0 }
            return QuickStopAction(
                familyKey: familyKey, targetFamilyKey: familyKey, displayName: displayName,
                title: title, shortTitle: shortTitle,
                detail: details.isEmpty ? nil : details.joined(separator: " · "),
                systemImage: image, emphasis: emphasis
            )
        }

        if risk.appQuitPID != nil {
            let kindDetail: String? = switch risk.kind {
            case .dataStore: "Gives it time to save data"
            case .containerRuntime: "Stops every container"
            default: nil
            }
            return action("Quit \(appName ?? displayName)…", "Quit…", "xmark.app", kindDetail)
        }
        switch risk.kind {
        case .dataStore:
            return action("Shut Down \(displayName)…", "Shut Down…", "power", "Gives it time to save data")
        case .containerRuntime:
            return action("Shut Down \(displayName)…", "Shut Down…", "power", "Stops every container")
        case .devServer:
            return action("Stop Server…", "Stop Server…", "server.rack", portsText(risk.freedPorts))
        case .packageManager:
            return action("Stop Install…", "Stop Install…", "shippingbox")
        case .build:
            return action("Stop Build…", "Stop Build…", "hammer")
        default:
            return action("Stop \(displayName)…", "Stop…", "stop.circle")
        }
    }

    private static func portsText(_ ports: [Int]) -> String? {
        guard !ports.isEmpty else { return nil }
        let listed = ports.prefix(3).map { ":\($0)" }.joined(separator: ", ")
        return "Frees \(listed)" + (ports.count > 3 ? " +\(ports.count - 3)" : "")
    }
}

public extension QuickStopAction {
    struct Candidate: Equatable, Sendable {
        public let familyKey: String
        public let level: GhostLevel

        public init(familyKey: String, level: GhostLevel) {
            self.familyKey = familyKey
            self.level = level
        }
    }

    /// Actions for the few families on screen. One sample index serves every
    /// candidate, and each family's workload is its own stop set and
    /// ancestor chain, so the cost does not grow with the sample per family.
    static func actions(
        for candidates: [Candidate],
        families: [ProcessFamily],
        processes: [ProcessMetrics],
        assessor: KillRiskAssessor = KillRiskAssessor()
    ) -> [String: QuickStopAction] {
        guard !candidates.isEmpty else { return [:] }
        var byKey: [String: ProcessFamily] = [:]
        for family in families {
            if byKey[family.familyKey] == nil { byKey[family.familyKey] = family }
            if byKey[family.signature.id] == nil { byKey[family.signature.id] = family }
        }
        let index = KillSampleIndex(processes)
        var ownedFamilyByPID: [Int32: ProcessFamily]?

        var result: [String: QuickStopAction] = [:]
        for candidate in candidates where result[candidate.familyKey] == nil {
            guard let family = byKey[candidate.familyKey] else { continue }
            let risk = assessor.assess(KillWorkloadProfile(root: family.root, index: index, family: family))
            var supervisorFamilyKey: String?
            if let pid = risk.supervisor?.pid {
                if ownedFamilyByPID == nil { ownedFamilyByPID = ownedFamiliesByPID(families) }
                supervisorFamilyKey = ownedFamilyByPID?[pid].map(\.familyKey)
            }
            result[candidate.familyKey] = make(
                familyKey: candidate.familyKey,
                displayName: family.displayName,
                level: candidate.level,
                heatConfirmed: family.score.heat.isConfirmed,
                hasOwnedTargets: !family.ownedIdentities.isEmpty,
                risk: risk,
                supervisorFamilyKey: supervisorFamilyKey,
                appName: risk.appQuitPID == nil ? nil : appBundleName(family.root.executablePath)
            )
        }
        return result
    }

    /// A supervisor is only worth redirecting to when it is a tracked family
    /// the user can stop.
    private static func ownedFamiliesByPID(_ families: [ProcessFamily]) -> [Int32: ProcessFamily] {
        var index: [Int32: ProcessFamily] = [:]
        for family in families where !family.ownedIdentities.isEmpty {
            for member in [family.root] + family.members where index[member.pid] == nil {
                index[member.pid] = family
            }
        }
        return index
    }

    private static func appBundleName(_ path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        let bundle = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
        return bundle.isEmpty ? nil : bundle
    }
}

public extension KillReport {
    /// The confirmation after a stop that left nothing running; nil when the
    /// user should stay on the result to see what survived or came back.
    var cleanStopToastText: String? {
        guard partiallySucceeded, survivorPIDs.isEmpty, respawnedPIDs.isEmpty else { return nil }
        let freed = realizedMemoryReclaimBytes > 0 ? " — freed \(RadarFormat.bytes(realizedMemoryReclaimBytes))" : ""
        return "Stopped \(displayName)\(freed)"
    }
}
