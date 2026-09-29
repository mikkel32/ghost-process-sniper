import Foundation

/// One process in a family's tree, nested under its parent so the page can
/// show every member in an outline without doing tree work in a view body.
public struct FamilyProcessTreeRow: Identifiable, Equatable, Sendable {
    public let id: ProcessIdentity
    public let name: String
    public let memoryBytes: UInt64
    public let memoryText: String
    public let cpuPercent: Double
    public let cpuText: String
    public let commandLine: String
    public let executablePath: String
    public let isRoot: Bool
    /// Owned by the current user and not a system process.
    public let isStoppable: Bool
    /// "+42 MB/min" for a member with a real share of the family's growth;
    /// nil for the rest, which is nearly every member of nearly every family.
    public let growthText: String?
    /// The member the engine names as the source of a credible leak.
    public let isGrowthCulprit: Bool
    /// Nil for a leaf, as hierarchical tables expect.
    public private(set) var children: [FamilyProcessTreeRow]?

    public var pid: Int32 { id.pid }

    /// A member is worth a growth figure from a tenth of the family's growth.
    static let minimumGrowthShare = 0.1
    /// Below this the figure would read "+0 MB/min": drift, not growth.
    static let minimumGrowthMegabytesPerMinute = 1.0

    /// Members whose parent is outside the family hang off the root, so no
    /// member is ever dropped. Siblings are ordered by memory, largest first.
    /// `growth` and `culprit` arrive already judged (the panel decides
    /// whether the family's history earns them), so the tree only draws them.
    public static func build(
        members: [ProcessMetrics],
        root: ProcessMetrics,
        ownedIdentities: [ProcessIdentity],
        growth: [MemberGrowth] = [],
        culprit: ProcessIdentity? = nil
    ) -> [FamilyProcessTreeRow] {
        guard !members.isEmpty else { return [] }
        let owned = Set(ownedIdentities)
        var growthTexts: [ProcessIdentity: String] = [:]
        for entry in growth where entry.share >= minimumGrowthShare && entry.slopeMegabytesPerMinute >= minimumGrowthMegabytesPerMinute {
            growthTexts[entry.identity] = "+" + RadarFormat.leak(entry.slopeMegabytesPerMinute)
        }
        let memberPIDs = Set(members.map(\.pid))
        var childrenByParent: [Int32: [ProcessMetrics]] = [:]
        for member in members where member.identity != root.identity {
            let parent = memberPIDs.contains(member.parentPID) && member.parentPID != member.pid ? member.parentPID : root.pid
            childrenByParent[parent, default: []].append(member)
        }
        var visited: Set<ProcessIdentity> = []

        func node(_ process: ProcessMetrics) -> FamilyProcessTreeRow {
            visited.insert(process.identity)
            let kids = (childrenByParent[process.pid] ?? [])
                .filter { !visited.contains($0.identity) }
                .sorted { lhs, rhs in
                    if lhs.memoryForScoringBytes != rhs.memoryForScoringBytes {
                        return lhs.memoryForScoringBytes > rhs.memoryForScoringBytes
                    }
                    return lhs.pid < rhs.pid
                }
            var childRows: [FamilyProcessTreeRow] = []
            for kid in kids where !visited.contains(kid.identity) {
                childRows.append(node(kid))
            }
            return FamilyProcessTreeRow(
                id: process.identity,
                name: process.name,
                memoryBytes: process.memoryForScoringBytes,
                memoryText: RadarFormat.bytes(process.memoryForScoringBytes),
                cpuPercent: process.cpuPercent,
                cpuText: RadarFormat.percent(process.cpuPercent),
                commandLine: process.commandLine,
                executablePath: process.executablePath,
                isRoot: process.identity == root.identity,
                isStoppable: owned.contains(process.identity) && !process.isSystemProcess,
                growthText: growthTexts[process.identity],
                isGrowthCulprit: process.identity == culprit,
                children: childRows.isEmpty ? nil : childRows
            )
        }

        let rootProcess = members.first { $0.identity == root.identity } ?? root
        var rows = [node(rootProcess)]
        // A parent cycle among non-root members would leave them unreached.
        for member in members where !visited.contains(member.identity) {
            rows.append(node(member))
        }
        return rows
    }

    /// The root, then the `limit - 1` biggest other processes wherever they
    /// sit in the outline, as a flat list: what a narrow column can show of
    /// a family with dozens of helpers. Built once with the panel.
    public static func largest(_ rows: [FamilyProcessTreeRow], limit: Int) -> [FamilyProcessTreeRow] {
        guard limit > 0 else { return [] }
        var all: [FamilyProcessTreeRow] = []
        func collect(_ rows: [FamilyProcessTreeRow]) {
            for row in rows {
                all.append(row)
                collect(row.children ?? [])
            }
        }
        collect(rows)
        all.sort { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
            return lhs.pid < rhs.pid
        }
        return all.prefix(limit).map { row in
            var flat = row
            flat.children = nil
            return flat
        }
    }
}
