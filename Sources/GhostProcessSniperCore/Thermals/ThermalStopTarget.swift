import Foundation

/// A shortcut from a heat suspect to the existing stop preview. Resolving one never
/// signals anything; the preview decides what can be stopped and asks first.
public struct ThermalStopTarget: Equatable, Sendable {
    public let familyKey: String
    public let title: String

    /// A contributor groups a whole app or job, but its family key points at the busiest
    /// member family (for Xcode that can be SourceKitService), so the title names the
    /// family the preview will actually open. System work, known macOS sources, families
    /// without user-owned processes and this app itself get no shortcut.
    public static func resolve(for contributor: ThermalContributor, family: ProcessFamily?,
                               ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> Self? {
        guard contributor.canInspectFamily, !contributor.isSystemProcess, contributor.knownSource == nil,
              let family, family.familyKey == contributor.familyKey || family.signature.id == contributor.familyKey,
              !family.ownedIdentities.isEmpty,
              family.root.identity.pid != ownPID, !family.members.contains(where: { $0.identity.pid == ownPID })
        else { return nil }
        let name = family.displayName
        let title = name == contributor.displayName ? "Stop \(name)…" : "Stop \(name) (\(contributor.displayName))…"
        return Self(familyKey: family.familyKey, title: title)
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
