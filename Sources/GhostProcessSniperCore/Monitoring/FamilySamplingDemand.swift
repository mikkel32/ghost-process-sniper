import Foundation

/// A single-pass, sample-local projection of which processes need richer reads.
/// Runtime family keys select one instance; logical signatures retain their
/// existing all-matching-instances behavior.
struct FamilySamplingDemand: Sendable {
    private(set) var highestLevel = GhostLevel.quiet
    private(set) var candidateIdentities = Set<ProcessIdentity>()
    private(set) var candidatePIDs = Set<Int32>()
    private(set) var forensicsIdentities = Set<ProcessIdentity>()
    private(set) var forensicsPIDs = Set<Int32>()
    /// Members of classified developer families: priority work without explicit demand.
    private(set) var devIdentities = Set<ProcessIdentity>()
    private(set) var hotFamilyCount = 0
    private(set) var focusedFamilyCount = 0

    static let developerConfidence = 0.45

    var reason: String {
        if hotFamilyCount > 0 { return "hot-family" }
        return focusedFamilyCount > 0 ? "focused-family" : "steady-state"
    }

    init(families: [ProcessFamily], focusedKeys: Set<String>) {
        for family in families {
            let escalates = family.forecastIsCredibleEscalation
            highestLevel = max(highestLevel,
                max(family.score.level, escalates ? family.forecast.state.level : .quiet))
            let isHot = family.score.level >= .hot || escalates ||
                family.alertState.kind == .new || family.alertState.kind == .recurring
            let isFocused = focusedKeys.contains(family.signature.id) ||
                (!focusedKeys.isEmpty && focusedKeys.contains(family.familyKey))
            let isPredictive = family.forecastIsCredibleEarlyWarning || family.score.level >= .watch

            if isHot { hotFamilyCount += 1 }
            if isFocused { focusedFamilyCount += 1 }
            if isPredictive || isFocused {
                candidatePIDs.insert(family.root.pid)
                candidateIdentities.formUnion(family.members.lazy.map(\.identity))
            }
            if isHot || isFocused {
                forensicsPIDs.insert(family.root.pid)
                forensicsIdentities.formUnion(family.members.lazy.map(\.identity))
            }
            if family.classification != nil || family.devConfidence >= Self.developerConfidence {
                devIdentities.formUnion(family.members.lazy.map(\.identity))
            }
        }
    }
}
