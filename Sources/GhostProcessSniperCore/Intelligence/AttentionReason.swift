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
        case largeButNormal(usual: UInt64)
        case aboveUsual(multiple: Double, usual: UInt64)
        /// `share` is the family's share of the memory in use.
        case hostPressure(share: Double?, detail: String)
        case overLimit(detail: String)
        case copies(Int)
        case forgotten(detail: String)
        case cpuAboveUsual(detail: String)
        case nearLimit(detail: String)
        case learningUsual
        case cpuOverLimit(detail: String)
        case buildWork(detail: String)
        case busyLoop(detail: String)
        case saturating(detail: String)
        case busyWhenUsuallyIdle(detail: String)
        case steadyBurn(minutes: Int, detail: String)
    }

    let kind: Kind

    /// Nil at Quiet, which has nothing to explain, and when none of the
    /// facts below is what raised the family. `cpuFirst` is for a family
    /// under the CPU cause: what its CPU is doing is asked before its size.
    init?(family: ProcessFamily, cpuFirst: Bool = false) {
        guard family.score.level >= .watch else { return nil }
        guard let kind = cpuFirst ? Self.cpuKind(for: family) ?? Self.kind(for: family) : Self.kind(for: family) else {
            return nil
        }
        self.kind = kind
    }

    private static func kind(for family: ProcessFamily) -> Kind? {
        let components = family.score.components
        func component(_ slot: String) -> GhostScoreComponent? { components.first { $0.slot == slot } }

        if let baseline = family.baseline, baseline.isMeasurementTrusted {
            let footprint = family.totalPhysicalFootprintBytes
            let usual = UInt64(baseline.meanMemoryBytes)
            let multiple = baseline.memoryMultiple(for: footprint)
            // The heat's own gate for the bigger-than-usual line: outside
            // the learned spread, or big enough that a wide one does not
            // excuse it. It says why the family is not held at Watch, or
            // why it is flagged at all.
            if multiple >= 1.3, baseline.memoryZScore(for: footprint) >= 3 || footprint > 512 * 1_048_576 {
                return .aboveUsual(multiple: multiple, usual: usual)
            }
            // Only at Watch: a Hot family is never reassured, whatever
            // evidence an earlier tick left behind.
            if family.score.level == .watch, family.score.heat.evidence.contains(where: { $0.hasPrefix(GhostHeat.usualSizeEvidence) }) {
                return .largeButNormal(usual: usual)
            }
        }

        // Memory over its limit is the fact; whether the Mac is short of
        // memory is why the limit is where it is, so it goes first. The
        // pressure component alone says little: any family over 512 MB
        // with a sliver of the memory in use carries it.
        if let memory = component("memory"), memory.level >= .hot {
            if let pressure = component("pressure") { return .hostPressure(share: pressure.ratio, detail: pressure.detail) }
            return .overLimit(detail: memory.detail)
        }
        // The score's own gate: copies it did not count are not why it is here.
        if let copies = family.duplicateCluster, copies.countsAsIndependentCopies, copies.copiesMatter {
            return .copies(copies.independentRootCount)
        }
        if let forgotten = component("forgotten") { return .forgotten(detail: forgotten.detail) }
        if let cpu = cpuKind(for: family) { return cpu }
        // Size is all that is left: say how close it is to the limit (the
        // last stretch before it is what the hardware floor makes Hot), or,
        // at Watch only, that its usual size is still being learned.
        guard family.totalPhysicalFootprintBytes >= 512 * 1_048_576,
              let memory = component("memory"), memory.level >= .watch else { return nil }
        if let ratio = memory.ratio, ratio >= 0.8 { return .nearLimit(detail: memory.detail) }
        if family.score.level == .watch, family.baseline?.isMeasurementTrusted != true { return .learningUsual }
        return nil
    }

    /// What the family's CPU is doing, when that is why it is here: a
    /// behavior the ledger proved, a learned usual it is above, or its limit.
    private static func cpuKind(for family: ProcessFamily) -> Kind? {
        let cpu = family.score.components.first { $0.slot == "cpu" }
        let overLimit = (cpu?.level ?? .quiet) >= .hot
        if let behavior = family.forecast.cpuBehavior, !behavior.reason.isEmpty {
            let detail = behavior.reason.prefix(1).uppercased() + behavior.reason.dropFirst()
            switch behavior.kind {
            case .spin: return .busyLoop(detail: detail)
            case .machineSaturation: return .saturating(detail: detail)
            case .idleServiceBurning: return .busyWhenUsuallyIdle(detail: detail)
            case .steadyBurn: return .steadyBurn(minutes: behavior.minutes, detail: detail)
            case .expectedBurst where overLimit || behavior.isRunaway: return .buildWork(detail: detail)
            case .none where behavior.isSustained: return .cpuOverLimit(detail: detail)
            default: break
            }
        }
        if let usual = family.score.components.first(where: { $0.slot == "baseline.cpu" }), usual.level >= .watch {
            return .cpuAboveUsual(detail: usual.title)
        }
        if let cpu, overLimit { return .cpuOverLimit(detail: cpu.detail) }
        return nil
    }

    /// Short enough for a 250 pt sidebar row: about 28 characters.
    var text: String {
        switch kind {
        case .largeButNormal: GhostHeat.usualSizeEvidence
        case let .aboveUsual(multiple, _): "\(RadarFormat.fixed1(multiple))x its usual size"
        // Every big family carries the pressure while the Mac is short:
        // its own share tells a queue of them apart.
        case let .hostPressure(share, _):
            share.map { Int(($0 * 100).rounded()) }.flatMap { $0 >= 1 ? "Holds \($0)% of scarce memory" : nil }
                ?? "Memory is tight on this Mac"
        case .overLimit: "Over its memory limit"
        case let .copies(count): "\(count) copies running"
        case .forgotten: "Probably forgotten"
        case .cpuAboveUsual: "CPU above its usual"
        case .nearLimit: "Near its memory limit"
        case .learningUsual: "Large; learning its usual"
        case .cpuOverLimit: "Over its CPU limit"
        case .buildWork: "Build or test work"
        case .busyLoop: "Busy-looping on one core"
        case .saturating: "Using most of this Mac's CPU"
        case .busyWhenUsuallyIdle: "Busy; it usually idles"
        case let .steadyBurn(minutes, _): "Busy for \(minutes) min"
        }
    }

    /// The numbers behind `text`, for the hero and tooltips. Unlike the
    /// generic sentence it replaces, it carries no "does not prove a leak"
    /// hedge: the reason is the claim, and it is not that.
    func evidence(memory: String, cpu: String) -> String {
        switch kind {
        case let .largeButNormal(usual): "\(memory), about its usual \(RadarFormat.bytes(usual)); \(cpu) CPU."
        case let .aboveUsual(_, usual): "\(memory) against a usual \(RadarFormat.bytes(usual)); \(cpu) CPU."
        case let .hostPressure(_, detail): "\(detail); \(memory) tracked footprint, \(cpu) CPU."
        case let .overLimit(detail): "\(detail); \(cpu) CPU."
        case let .copies(count): "\(count) independent copies are running; this one holds \(memory), \(cpu) CPU."
        case let .forgotten(detail): "\(detail); \(memory) tracked footprint, \(cpu) CPU."
        case let .cpuAboveUsual(detail): "\(detail); \(memory) tracked footprint."
        case let .nearLimit(detail): "\(detail); \(cpu) CPU."
        case .learningUsual: "\(memory), \(cpu) CPU. Its usual size is learned over about twenty minutes."
        case let .cpuOverLimit(detail), let .buildWork(detail), let .busyLoop(detail), let .saturating(detail),
             let .busyWhenUsuallyIdle(detail), let .steadyBurn(_, detail):
            "\(detail); \(memory) tracked footprint."
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
