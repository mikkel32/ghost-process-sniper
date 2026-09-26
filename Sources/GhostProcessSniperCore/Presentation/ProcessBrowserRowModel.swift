import Foundation

/// One row of the process browser table: a tracked family or an untracked
/// process that matched the search, with the same columns for both.
public struct ProcessBrowserRowModel: Identifiable, Equatable, Sendable {
    /// The family key, or "pid:<pid>:<start>" for an untracked process, so
    /// selection survives refreshes and never collides between the two.
    public let id: String
    public let familyKey: String?
    public let identity: ProcessIdentity
    public let name: String
    public let nameHighlights: [Range<Int>]
    public let detail: String
    public let memoryBytes: UInt64
    public let memoryText: String
    public let cpuPercent: Double
    public let cpuText: String
    public let leakVelocity: Double
    public let statusText: String
    /// Nil for untracked processes, which have no verdict.
    public let level: GhostLevel?
    public let pid: Int32
    public let executablePath: String
    public let commandLine: String
    public let isStoppable: Bool

    public var isTracked: Bool { familyKey != nil }
    /// Sort key for the Status column: tracked by level, untracked last.
    public var statusRank: Int { level.map { $0.rawValue + 1 } ?? 0 }

    public init(family row: FamilyTriageViewModel, match: ProcessSearchMatch?, executablePath: String, commandLine: String) {
        id = row.familyKey
        familyKey = row.familyKey
        identity = row.familyID
        name = row.displayName
        nameHighlights = match?.nameHighlights ?? []
        detail = match?.reason ?? row.assessment.cause
        memoryBytes = row.memoryBytes
        memoryText = row.memoryText
        cpuPercent = row.cpuPercent
        cpuText = row.cpuText
        leakVelocity = row.leakVelocity
        statusText = row.assessment.status
        level = row.level
        pid = row.familyID.pid
        self.executablePath = executablePath
        self.commandLine = commandLine
        isStoppable = row.isKillable
    }

    public init(process row: ProcessSearchRowModel) {
        id = Self.untrackedID(row.id)
        familyKey = nil
        identity = row.id
        name = row.name
        nameHighlights = row.nameHighlights
        detail = row.detail.isEmpty ? row.ownerName : row.detail
        memoryBytes = row.memoryBytes
        memoryText = row.memoryText
        cpuPercent = row.cpuPercent
        cpuText = row.cpuText
        leakVelocity = 0
        statusText = "Not tracked"
        level = nil
        pid = row.pid
        executablePath = row.executablePath
        commandLine = row.commandLine
        isStoppable = row.isStoppable
    }

    public static func untrackedID(_ identity: ProcessIdentity) -> String {
        "pid:\(identity.pid):\(identity.startTimeSeconds).\(identity.startTimeMicroseconds)"
    }

    /// Tracked families first in smart order; any other sort ranks tracked
    /// and untracked rows together. `ascending` is literal: names A to Z,
    /// numbers smallest first.
    static func ordered(
        tracked: [ProcessBrowserRowModel],
        untracked: [ProcessBrowserRowModel],
        sort: RadarSort,
        ascending: Bool
    ) -> [ProcessBrowserRowModel] {
        let reverse = ascending != sort.isNaturallyAscending
        guard sort != .smart else {
            return (reverse ? tracked.reversed() : tracked) + untracked
        }
        let merged = (tracked + untracked).sorted { lhs, rhs in
            switch sort {
            case .memory where lhs.memoryBytes != rhs.memoryBytes: return lhs.memoryBytes > rhs.memoryBytes
            case .cpu where lhs.cpuPercent != rhs.cpuPercent: return lhs.cpuPercent > rhs.cpuPercent
            case .leak where lhs.leakVelocity != rhs.leakVelocity: return lhs.leakVelocity > rhs.leakVelocity
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            default:
                break
            }
            if lhs.isTracked != rhs.isTracked { return lhs.isTracked }
            return lhs.id < rhs.id
        }
        return reverse ? merged.reversed() : merged
    }
}

extension RadarSort {
    /// Names read A to Z; every metric reads biggest first.
    public var isNaturallyAscending: Bool { self == .name }
}

extension RadarSort {
    /// The sort a browser table column header selects. Status is priority
    /// order; no column (a cleared header) is priority order too.
    public init(browserColumn keyPath: PartialKeyPath<ProcessBrowserRowModel>?) {
        self = switch keyPath {
        case \ProcessBrowserRowModel.name: .name
        case \ProcessBrowserRowModel.memoryBytes: .memory
        case \ProcessBrowserRowModel.cpuPercent: .cpu
        case \ProcessBrowserRowModel.leakVelocity: .leak
        default: .smart
        }
    }
}

/// What "Reveal in Finder" should select for a process.
public enum FinderReveal {
    /// The app bundle for anything inside one, since Finder cannot show a
    /// binary buried in Contents/MacOS usefully; otherwise the executable.
    public static func path(forExecutable path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path
    }
}
