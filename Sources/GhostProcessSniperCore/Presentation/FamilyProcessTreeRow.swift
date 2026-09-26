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
    /// Nil for a leaf, as hierarchical tables expect.
    public let children: [FamilyProcessTreeRow]?

    public var pid: Int32 { id.pid }

    /// Members whose parent is outside the family hang off the root, so no
    /// member is ever dropped. Siblings are ordered by memory, largest first.
    public static func build(members: [ProcessMetrics], root: ProcessMetrics, ownedIdentities: [ProcessIdentity]) -> [FamilyProcessTreeRow] {
        guard !members.isEmpty else { return [] }
        let owned = Set(ownedIdentities)
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
}
