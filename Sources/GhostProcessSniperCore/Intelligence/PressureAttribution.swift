import Foundation

/// How much of the Mac's memory trouble one family accounts for.
public struct PressureShare: Equatable, Sendable {
    /// Share of the memory in use.
    public let footprintShare: Double
    /// Share of the credible growth across all families.
    public let growthShare: Double
    /// The family's own credible growth. A share is relative: the only family
    /// growing has all of the growth, however little that is.
    public let growthMegabytesPerMinute: Double

    /// Growth that counts as driving host pressure: below it the family is a
    /// trickle whatever its share, so it earns a part of the boost and no
    /// vote. Also the least total growth the host outlook counts.
    public static let materialGrowthMegabytesPerMinute: Double = 20

    public static let none = PressureShare(footprintShare: 0, growthShare: 0)

    /// Without a rate, the growth is taken as material: a share built by hand
    /// judges as before.
    public init(footprintShare: Double, growthShare: Double,
                growthMegabytesPerMinute: Double = PressureShare.materialGrowthMegabytesPerMinute) {
        self.footprintShare = min(1, max(0, footprintShare))
        self.growthShare = min(1, max(0, growthShare))
        self.growthMegabytesPerMinute = max(0, growthMegabytesPerMinute)
    }

    public var contribution: Double { max(footprintShare, growthShare) }

    /// How much of `materialGrowthMegabytesPerMinute` the family's growth is, at most all.
    private var growthMateriality: Double { min(1, growthMegabytesPerMinute / Self.materialGrowthMegabytesPerMinute) }

    /// Scales the host-pressure boost: a family holding a quarter of used
    /// memory gets all of it, and so does one with a quarter of the growth,
    /// once that growth is material (a trickle earns a part in proportion);
    /// an idle bystander little.
    public var boostScale: Double {
        max(min(1, footprintShare / 0.25), min(1, growthShare / 0.25) * growthMateriality)
    }

    /// Only a family driving the growth is corroborated by host pressure:
    /// most of it, and enough of it to matter.
    public var corroboratesPressure: Bool { growthShare >= 0.3 && growthMateriality >= 1 }

    /// "38% of used memory, 71% of recent growth". A trickle's growth is not
    /// worth the claim.
    public var text: String {
        let memory = "\(Int((footprintShare * 100).rounded()))% of used memory"
        guard growthShare > 0, growthMateriality >= 1 else { return memory }
        return memory + ", \(Int((growthShare * 100).rounded()))% of recent growth"
    }
}

/// When the Mac's memory pressure turns critical at the current credible
/// growth, and who drives it.
public struct HostMemoryOutlook: Equatable, Sendable {
    public let etaSeconds: TimeInterval
    public let growthMegabytesPerMinute: Double
    /// Family keys, largest growth first.
    public let topContributors: [String]
    public let topContributorName: String?
}

/// Attributes host memory pressure to families by footprint and credible
/// growth, and projects when pressure turns critical.
public enum PressureAttribution {
    /// Free memory below this is where macOS pressure turns critical:
    /// 8% of RAM, at least 1 GB.
    public static func criticalReserve(totalBytes: UInt64) -> UInt64 {
        max(totalBytes / 100 * 8, 1 << 30)
    }

    /// Growth proven by history: the short window's credible velocity, or a
    /// long-term slow leak.
    public static func credibleGrowth(of family: ProcessFamily, physicalMemoryBytes: UInt64) -> Double {
        let longTerm = family.longTermTrend.isSlowLeak(physicalMemoryBytes: physicalMemoryBytes)
            ? family.longTermTrend.slopeMegabytesPerMinute : 0
        return max(0, family.trend.credibleMemoryVelocity, longTerm)
    }

    public static func compute(families: [ProcessFamily], pressure: SystemMemoryPressure) -> [String: PressureShare] {
        guard pressure.isKnown else { return [:] }
        let used = Double(pressure.totalBytes - min(pressure.availableBytes, pressure.totalBytes))
        let growth = families.map { credibleGrowth(of: $0, physicalMemoryBytes: pressure.totalBytes) }
        let totalGrowth = growth.reduce(0, +)
        var shares: [String: PressureShare] = [:]
        shares.reserveCapacity(families.count)
        for (family, familyGrowth) in zip(families, growth) {
            shares[family.familyKey] = PressureShare(
                footprintShare: used > 0 ? Double(family.totalPhysicalFootprintBytes) / used : 0,
                growthShare: totalGrowth > 0 ? familyGrowth / totalGrowth : 0,
                growthMegabytesPerMinute: familyGrowth
            )
        }
        return shares
    }

    /// A family judged alone, when no attribution was computed for the tick:
    /// its footprint share, and all the growth if it is growing.
    public static func share(for family: ProcessFamily, pressure: SystemMemoryPressure) -> PressureShare {
        let used = Double(pressure.totalBytes - min(pressure.availableBytes, pressure.totalBytes))
        let growth = credibleGrowth(of: family, physicalMemoryBytes: pressure.totalBytes)
        return PressureShare(
            footprintShare: used > 0 ? Double(family.totalPhysicalFootprintBytes) / used : 0,
            growthShare: growth > 0 ? 1 : 0,
            growthMegabytesPerMinute: growth
        )
    }

    /// Only with at least `PressureShare.materialGrowthMegabytesPerMinute` of
    /// credible growth and pressure already elevated; macOS compresses and
    /// swaps long before it runs out, so the target is critical pressure, not
    /// zero free memory.
    public static func outlook(families: [ProcessFamily], pressure: SystemMemoryPressure) -> HostMemoryOutlook? {
        guard let headroom = headroomMegabytes(pressure), pressure.level >= .elevated else { return nil }
        let growing = families
            .map { ($0, credibleGrowth(of: $0, physicalMemoryBytes: pressure.totalBytes)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        let total = growing.reduce(0) { $0 + $1.1 }
        guard total >= PressureShare.materialGrowthMegabytesPerMinute else { return nil }
        return HostMemoryOutlook(
            etaSeconds: headroom / total * 60,
            growthMegabytesPerMinute: total,
            topContributors: growing.map(\.0.familyKey),
            topContributorName: growing.first?.0.displayName
        )
    }

    /// The seconds until this family alone brings pressure to critical.
    public static func familyETASeconds(velocity: Double, pressure: SystemMemoryPressure) -> TimeInterval? {
        guard let headroom = headroomMegabytes(pressure), velocity > 0 else { return nil }
        return headroom / velocity * 60
    }

    /// Free memory left above the critical reserve. Nil once pressure is
    /// critical or the reserve is already spent: there is nothing left to
    /// count down to, and a zero ETA would read as a breach of the family's
    /// own limit.
    private static func headroomMegabytes(_ pressure: SystemMemoryPressure) -> Double? {
        guard pressure.isKnown, pressure.level < .critical else { return nil }
        let headroom = Double(pressure.availableBytes) - Double(criticalReserve(totalBytes: pressure.totalBytes))
        return headroom > 0 ? headroom / 1_048_576 : nil
    }

    /// "~9 min", "~2 hr".
    public static func etaText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "<1 min" }
        if seconds < 3_600 { return "~\(Int((seconds / 60).rounded(.up))) min" }
        return "~\(RadarFormat.fixed1(seconds / 3_600)) hr"
    }
}
