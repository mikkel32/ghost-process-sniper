import Foundation

/// A shortcut from a heat suspect to the existing stop preview. Resolving one never
/// signals anything; the preview decides what can be stopped and asks first.
public struct ThermalStopTarget: Equatable, Sendable {
    public let familyKey: String
    public let title: String
    /// The family's Quick Stop, so emphasis and routing follow the same rules
    /// as every other stop shortcut: red only when recommended.
    public let action: QuickStopAction

    /// A contributor groups a whole app or job, but its family key points at the busiest
    /// member family (for Xcode that can be SourceKitService), so the title names the
    /// family the preview will actually open. System work, known macOS sources, families
    /// without user-owned processes and this app itself get no shortcut. With `risk`,
    /// an app is quit rather than stopped, as on its Quick Stop.
    public static func resolve(for contributor: ThermalContributor, family: ProcessFamily?,
                               risk: KillRiskAssessment = .none,
                               ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> Self? {
        guard contributor.canInspectFamily, !contributor.isSystemProcess, contributor.knownSource == nil,
              let family, family.familyKey == contributor.familyKey || family.signature.id == contributor.familyKey,
              !family.ownedIdentities.isEmpty,
              family.root.identity.pid != ownPID, !family.members.contains(where: { $0.identity.pid == ownPID })
        else { return nil }
        let name = family.displayName
        let verb = risk.appQuitPID == nil ? "Stop" : "Quit"
        let title = name == contributor.displayName ? "\(verb) \(name)…" : "\(verb) \(name) (\(contributor.displayName))…"
        let action = QuickStopAction.make(familyKey: family.familyKey, displayName: name, level: family.score.level,
                                          heatConfirmed: family.score.heat.isConfirmed, hasOwnedTargets: true, risk: risk)
        return Self(familyKey: family.familyKey, title: title, action: action)
    }
}

public extension ThermalAppInsight {
    /// The heat suspect strong enough for a prominent stop shortcut: user work seen
    /// repeatedly while heat needs review. Weaker findings keep Inspect only.
    func stopCandidate(diagnosis: ThermalDiagnosis) -> ThermalContributor? {
        guard evidenceStrength == .repeated, Self.heatNeedsReview(diagnosis), let contributor,
              contributor.canInspectFamily, !contributor.isSystemProcess, contributor.knownSource == nil
        else { return nil }
        return contributor
    }
}
