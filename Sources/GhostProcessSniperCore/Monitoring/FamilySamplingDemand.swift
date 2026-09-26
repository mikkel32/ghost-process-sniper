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
    /// Members of developer families: sampling hints and port-census candidates.
    private(set) var devIdentities = Set<ProcessIdentity>()
    private(set) var hotFamilyCount = 0
    private(set) var focusedFamilyCount = 0

    static let developerConfidence = 0.45

    var reason: String {
        if hotFamilyCount > 0 { return "hot-family" }
        return focusedFamilyCount > 0 ? "focused-family" : "steady-state"
    }

    /// How many incomplete families get rich reads per pass; `pass` rotates
    /// through the rest so none starves.
    static let incompleteFamiliesPerPass = 4

    init(families: [ProcessFamily], focusedKeys: Set<String>, pass: UInt64 = 0) {
        // A quiet family whose members lack current readings can never earn
        // Watch, so it would never be sampled richly: break that loop for
        // dev families.
        let incomplete = families.filter { !$0.coverage.isScorable && $0.devConfidence >= 0.35 }
        if !incomplete.isEmpty {
            let perPass = Self.incompleteFamiliesPerPass
            let start = Int((pass % UInt64(incomplete.count)) * UInt64(perPass) % UInt64(incomplete.count))
            for offset in 0..<min(perPass, incomplete.count) {
                let family = incomplete[(start + offset) % incomplete.count]
                candidatePIDs.insert(family.root.pid)
                candidateIdentities.formUnion(family.members.lazy.map(\.identity))
            }
        }
        // A forgotten server is quiet, so it is never hot enough for
        // forensics; one idle unattended dev root per pass gets them so its
        // working directory and ports are known.
        let unattended = families.filter { family in
            family.devConfidence >= 0.35 && family.forensics.currentDirectory == nil &&
                (family.forgotten?.launchContext.isUnattended ?? false) &&
                (family.forgotten?.idleSeconds ?? 0) >= ForgottenProcessAssessor.idleThreshold
        }
        if !unattended.isEmpty {
            let family = unattended[Int(pass % UInt64(unattended.count))]
            forensicsPIDs.insert(family.root.pid)
            forensicsIdentities.insert(family.root.identity)
        }
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
            if Self.isDeveloperWork(family) {
                devIdentities.formUnion(family.members.lazy.map(\.identity))
            }
        }
    }

    /// Every family carries a classification, so only a confident, specific
    /// one counts; "Heavy process" is the classifier's fallback, not evidence.
    static func isDeveloperWork(_ family: ProcessFamily) -> Bool {
        if family.devConfidence >= developerConfidence { return true }
        guard let classification = family.classification else { return false }
        return classification.kind != .unknownHeavy && classification.confidence >= developerConfidence
    }
}
