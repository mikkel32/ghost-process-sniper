import Foundation

/// Why a family is on the radar, in a few words a row can hold. It replaces
/// the "Memory footprint" and "Activity to review" that every big or merely
/// flagged family used to share, so a queue of nine rows is not nine copies
/// of one sentence.
///
/// Typed facts decide it (score components, the duplicate cluster), first
/// match wins, and a family with no specific reason has none: the caller
/// keeps the generic label rather than a guess.
struct AttentionReason: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case hostPressure(detail: String)
        case overLimit(detail: String)
        case copies(Int)
        case forgotten(detail: String)
        case cpuAboveUsual(detail: String)
    }

    let kind: Kind

    /// Nil at Quiet, which has nothing to explain, and when none of the
    /// facts below is what raised the family.
    init?(family: ProcessFamily) {
        guard family.score.level >= .watch, let kind = Self.kind(for: family) else { return nil }
        self.kind = kind
    }

    private static func kind(for family: ProcessFamily) -> Kind? {
        let components = family.score.components
        func component(_ slot: String) -> GhostScoreComponent? { components.first { $0.slot == slot } }

        // Memory over its limit is the fact; whether the Mac is short of
        // memory is why the limit is where it is, so it goes first. The
        // pressure component alone says little: any family over 512 MB
        // with a sliver of the memory in use carries it.
        if let memory = component("memory"), memory.level >= .hot {
            if let pressure = component("pressure") { return .hostPressure(detail: pressure.detail) }
            return .overLimit(detail: memory.detail)
        }
        if let copies = family.duplicateCluster, copies.countsAsIndependentCopies {
            return .copies(copies.independentRootCount)
        }
        if let forgotten = component("forgotten") { return .forgotten(detail: forgotten.detail) }
        if let cpu = component("baseline.cpu"), cpu.level >= .watch { return .cpuAboveUsual(detail: cpu.title) }
        return nil
    }

    /// Short enough for a 250 pt sidebar row: about 28 characters.
    var text: String {
        switch kind {
        case .hostPressure: "Memory is tight on this Mac"
        case .overLimit: "Over its memory limit"
        case let .copies(count): "\(count) copies running"
        case .forgotten: "Probably forgotten"
        case .cpuAboveUsual: "CPU above its usual"
        }
    }

    /// The numbers behind `text`, for the hero and tooltips. Unlike the
    /// generic sentence it replaces, it carries no "does not prove a leak"
    /// hedge: the reason is the claim, and it is not that.
    func evidence(memory: String, cpu: String) -> String {
        switch kind {
        case let .hostPressure(detail): "\(detail); \(memory) tracked footprint, \(cpu) CPU."
        case let .overLimit(detail): "\(detail); \(cpu) CPU."
        case let .copies(count): "\(count) independent copies are running; this one holds \(memory), \(cpu) CPU."
        case let .forgotten(detail): "\(detail); \(memory) tracked footprint, \(cpu) CPU."
        case let .cpuAboveUsual(detail): "\(detail); \(memory) tracked footprint."
        }
    }

    /// The reason as the end of a sentence ("Claude: memory is tight on this
    /// Mac"). Only a plain capitalised first word is lowercased, so "CPU
    /// above its usual" and "2 copies running" keep theirs.
    static func inSentence(_ reason: String) -> String {
        guard let first = reason.first, first.isUppercase, reason.dropFirst().first?.isLowercase == true else { return reason }
        return first.lowercased() + reason.dropFirst()
    }
}
