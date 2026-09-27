import Foundation

/// One process's searchable text, folded once and reused across keystrokes.
public struct SearchableProcess: Equatable, Sendable {
    /// Long command lines (Java class paths, Electron flags) are only
    /// searched this far; the interesting part is almost always earlier.
    static let commandCharacterLimit = 4_096

    public let pid: Int32
    public let displayName: String
    public let commandLine: String
    public let executablePath: String
    public let ownerName: String
    public let listeningPorts: [Int]
    let name: FoldedText
    let command: FoldedText
    let path: FoldedText
    let owner: FoldedText

    public init(
        pid: Int32,
        name: String,
        commandLine: String,
        executablePath: String,
        ownerName: String,
        listeningPorts: [Int] = []
    ) {
        self.pid = pid
        displayName = name
        self.commandLine = commandLine
        self.executablePath = executablePath
        self.ownerName = ownerName
        self.listeningPorts = listeningPorts
        self.name = FoldedText(name, tracksCharacters: true)
        // A command line that only repeats the name or path adds nothing.
        command = commandLine == name || commandLine == executablePath
            ? .empty
            : FoldedText(commandLine, maxCharacters: Self.commandCharacterLimit)
        path = FoldedText(executablePath)
        owner = FoldedText(ownerName)
    }

    /// Reuses folded text when only live data (such as ports) changed.
    func updating(listeningPorts ports: [Int]) -> SearchableProcess {
        guard ports != listeningPorts else { return self }
        return SearchableProcess(copying: self, listeningPorts: ports)
    }

    private init(copying other: SearchableProcess, listeningPorts: [Int]) {
        pid = other.pid
        displayName = other.displayName
        commandLine = other.commandLine
        executablePath = other.executablePath
        ownerName = other.ownerName
        self.listeningPorts = listeningPorts
        name = other.name
        command = other.command
        path = other.path
        owner = other.owner
    }
}

public struct SearchMeasurements: Equatable, Sendable {
    public var cpuPercent: Double
    public var memoryBytes: Double
    public var gpuPercent: Double
    public var threads: Double
    /// Only radar-assessed families carry growth and helper counts.
    public var leakMegabytesPerMinute: Double?
    public var children: Double?
    /// Nil until two reads of the process exist.
    public var energyWatts: Double?
    public var idleWakeupsPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?

    public init(
        cpuPercent: Double,
        memoryBytes: Double,
        gpuPercent: Double,
        threads: Double,
        leakMegabytesPerMinute: Double? = nil,
        children: Double? = nil,
        energyWatts: Double? = nil,
        idleWakeupsPerSecond: Double? = nil,
        diskWriteBytesPerSecond: Double? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
        self.threads = threads
        self.leakMegabytesPerMinute = leakMegabytesPerMinute
        self.children = children
        self.energyWatts = energyWatts
        self.idleWakeupsPerSecond = idleWakeupsPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
    }

    /// Sums the rates of the members that have them; nil when none does.
    init(power members: [ProcessMetrics], base: SearchMeasurements) {
        self = base
        var watts: Double?
        var wakeups: Double?
        var writes: Double?
        for member in members {
            if let value = member.power.watts { watts = (watts ?? 0) + value }
            if let value = member.power.idleWakeupsPerSecond { wakeups = (wakeups ?? 0) + value }
            if let value = member.power.diskWriteBytesPerSecond { writes = (writes ?? 0) + value }
        }
        energyWatts = watts
        idleWakeupsPerSecond = wakeups
        diskWriteBytesPerSecond = writes
    }

    func value(for metric: ProcessSearchQuery.Metric) -> Double? {
        switch metric {
        case .cpu: cpuPercent
        case .memory: memoryBytes
        case .gpu: gpuPercent
        case .threads: threads
        case .leak: leakMegabytesPerMinute
        case .children: children
        case .energy: energyWatts
        case .wakeups: idleWakeupsPerSecond
        case .writes: diskWriteBytesPerSecond
        }
    }
}

/// A tracked family (root plus helpers) or one untracked process.
public struct SearchSubject: Sendable {
    public let root: SearchableProcess
    public let helpers: [SearchableProcess]
    public let kindLabel: String
    public let measurements: SearchMeasurements
    public let flags: Set<ProcessSearchQuery.Flag>
    let kind: FoldedText

    public init(
        root: SearchableProcess,
        helpers: [SearchableProcess] = [],
        kindLabel: String = "",
        measurements: SearchMeasurements,
        flags: Set<ProcessSearchQuery.Flag>
    ) {
        self.root = root
        self.helpers = helpers
        self.kindLabel = kindLabel
        self.measurements = measurements
        self.flags = flags
        kind = FoldedText(kindLabel)
    }
}

public struct ProcessSearchMatch: Equatable, Sendable {
    public let score: Double
    /// Character ranges of the root's display name to emphasize.
    public let nameHighlights: [Range<Int>]
    /// Why the row matched when the name alone does not show it.
    public let reason: String?
}

public struct ProcessSearchOutcome: Equatable, Sendable {
    public let families: [Int: ProcessSearchMatch]
    public let processes: [Int: ProcessSearchMatch]
    /// No exact match existed, so these are typo-tolerant and acronym guesses.
    public let isApproximate: Bool

    public static let none = ProcessSearchOutcome(families: [:], processes: [:], isApproximate: false)
}

public enum ProcessSearchEngine {
    /// Exact matching runs first. Only when nothing at all matches does the
    /// engine retry with acronyms, subsequences and typos, so close guesses
    /// never crowd out real results.
    public static func search(
        _ query: ProcessSearchQuery,
        families: [SearchSubject],
        processes: [SearchSubject]
    ) -> ProcessSearchOutcome {
        let exact = ProcessSearchOutcome(
            families: matches(query, families, fuzzy: false),
            processes: matches(query, processes, fuzzy: false),
            isApproximate: false
        )
        let canGuess = query.terms.contains { !$0.isNegated && ($0.field == .any || $0.field == .name) }
        guard exact.families.isEmpty, exact.processes.isEmpty, canGuess else { return exact }
        return ProcessSearchOutcome(
            families: matches(query, families, fuzzy: true),
            processes: matches(query, processes, fuzzy: true),
            isApproximate: true
        )
    }

    private static func matches(_ query: ProcessSearchQuery, _ subjects: [SearchSubject], fuzzy: Bool) -> [Int: ProcessSearchMatch] {
        var result: [Int: ProcessSearchMatch] = [:]
        for (index, subject) in subjects.enumerated() {
            if let match = evaluate(query, subject, fuzzy: fuzzy) { result[index] = match }
        }
        return result
    }

    static func evaluate(_ query: ProcessSearchQuery, _ subject: SearchSubject, fuzzy: Bool) -> ProcessSearchMatch? {
        for filter in query.flags where subject.flags.contains(filter.flag) == filter.isNegated {
            return nil
        }
        for filter in query.metrics where !filter.accepts(subject.measurements.value(for: filter.metric)) {
            return nil
        }

        var score = 0.0
        var nameOffsets: [Int] = []
        var reason: String?

        for filter in query.pids {
            let hit = subject.process(where: { filter.values.contains(Int($0.pid)) })
            if (hit != nil) == filter.isNegated { return nil }
            if let hit {
                score += hit.isRoot ? 120 : 90
                if !hit.isRoot { reason = reason ?? "Includes \(hit.process.displayName) \u{00b7} PID \(hit.process.pid)" }
            }
        }
        for filter in query.ports {
            let hit = subject.process(where: { !filter.values.isDisjoint(with: $0.listeningPorts) })
            if (hit != nil) == filter.isNegated { return nil }
            if let hit {
                score += 95
                let port = hit.process.listeningPorts.first(where: filter.values.contains) ?? 0
                reason = reason ?? portReason(port, hit)
            }
        }

        for term in query.terms {
            let best = bestHit(for: term, in: subject, fuzzy: fuzzy && !term.isNegated)
            if term.isNegated {
                if best != nil { return nil }
                continue
            }
            guard let best else { return nil }
            score += best.points
            if case .rootName = best.location, let match = best.match {
                nameOffsets.append(contentsOf: match.byteOffsets)
            } else if reason == nil {
                reason = describe(best, in: subject)
            }
        }

        let highlights = subject.root.name.characterRanges(for: Array(Set(nameOffsets)).sorted())
        return ProcessSearchMatch(score: score, nameHighlights: highlights, reason: reason)
    }

    // MARK: - Term scoring

    private enum Location {
        case rootName, helperName(Int), command(Int?), path(Int?), owner(Int?), kind, pid(Int?), port(Int?, Int)
    }

    private struct Hit {
        let points: Double
        let location: Location
        let match: TextMatch?
    }

    private static func bestHit(for term: ProcessSearchQuery.Term, in subject: SearchSubject, fuzzy: Bool) -> Hit? {
        var best: Hit?
        func consider(_ text: FoldedText, weight: Double, fuzzy allowsFuzzy: Bool = false, _ location: Location) {
            guard let match = TextMatcher.match(term.folded, in: text, fuzzy: fuzzy && allowsFuzzy) else { return }
            let points = match.score * weight
            if points > (best?.points ?? 0) { best = Hit(points: points, location: location, match: match) }
        }
        func considerIdentity(_ points: Double, _ location: Location) {
            if points > (best?.points ?? 0) { best = Hit(points: points, location: location, match: nil) }
        }

        let root = subject.root
        let field = term.field
        if field == .any || field == .name {
            consider(root.name, weight: 100, fuzzy: true, .rootName)
            for (index, helper) in subject.helpers.enumerated() {
                consider(helper.name, weight: 72, fuzzy: true, .helperName(index))
            }
        }
        if field == .any || field == .command {
            consider(root.command, weight: 50, .command(nil))
            for (index, helper) in subject.helpers.enumerated() {
                consider(helper.command, weight: 40, .command(index))
            }
        }
        if field == .any || field == .path {
            consider(root.path, weight: 45, .path(nil))
            for (index, helper) in subject.helpers.enumerated() {
                consider(helper.path, weight: 35, .path(index))
            }
        }
        if field == .any || field == .kind {
            consider(subject.kind, weight: 30, .kind)
        }
        if field == .user {
            consider(root.owner, weight: 40, .owner(nil))
            for (index, helper) in subject.helpers.enumerated() {
                consider(helper.owner, weight: 30, .owner(index))
            }
        }
        if field == .any, let number = term.number {
            if Int(root.pid) == number { considerIdentity(120, .pid(nil)) }
            if let index = subject.helpers.firstIndex(where: { Int($0.pid) == number }) { considerIdentity(90, .pid(index)) }
            if root.listeningPorts.contains(number) {
                considerIdentity(95, .port(nil, number))
            } else if let index = subject.helpers.firstIndex(where: { $0.listeningPorts.contains(number) }) {
                considerIdentity(95, .port(index, number))
            }
        }
        return best
    }

    // MARK: - Explanations

    private static func describe(_ hit: Hit, in subject: SearchSubject) -> String? {
        func process(_ index: Int?) -> SearchableProcess {
            index.map { subject.helpers[$0] } ?? subject.root
        }
        switch hit.location {
        case .rootName:
            return nil
        case .helperName(let index):
            let helper = subject.helpers[index]
            return "Includes \(helper.displayName) \u{00b7} PID \(helper.pid)"
        case .command(let index):
            let owner = process(index)
            let text = snippet(owner.commandLine, around: hit.match?.byteOffsets ?? [], limit: SearchableProcess.commandCharacterLimit)
            return index == nil ? "Command: \(text)" : "\(owner.displayName) (PID \(owner.pid)): \(text)"
        case .path(let index):
            let owner = process(index)
            let text = snippet(owner.executablePath, around: hit.match?.byteOffsets ?? [])
            return index == nil ? "Path: \(text)" : "\(owner.displayName) at \(text)"
        case .owner(let index):
            return "Owner: \(process(index).ownerName)"
        case .kind:
            return "Kind: \(subject.kindLabel)"
        case .pid(let index):
            let owner = process(index)
            return index == nil ? "PID \(owner.pid)" : "Includes \(owner.displayName) \u{00b7} PID \(owner.pid)"
        case .port(let index, let port):
            return portReason(port, (process(index), index == nil))
        }
    }

    private static func portReason(_ port: Int, _ hit: (process: SearchableProcess, isRoot: Bool)) -> String {
        hit.isRoot ? "Listening on port \(port)" : "\(hit.process.displayName) listens on port \(port)"
    }

    /// Shows the matched part of a long string with a little context.
    static func snippet(_ text: String, around byteOffsets: [Int], limit: Int = .max) -> String {
        let total: Int
        let span: Range<Int>?
        let slice: (Range<Int>) -> String
        if text.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x0D }) {
            // Plain ASCII (nearly every command line): folded bytes line up
            // with characters, so there is no need to fold the text again.
            let bytes = Array(text.utf8)
            total = bytes.count
            span = byteOffsets.min().map { $0..<((byteOffsets.max() ?? $0) + 1) }
            slice = { String(decoding: bytes[$0], as: UTF8.self) }
        } else {
            let ranges = FoldedText(text, tracksCharacters: true, maxCharacters: limit).characterRanges(for: byteOffsets)
            let characters = Array(text)
            total = characters.count
            span = ranges.first.map { $0.lowerBound..<(ranges.last?.upperBound ?? $0.upperBound) }
            slice = { String(characters[$0]) }
        }
        guard total > 72 else { return text }
        guard let span, span.lowerBound < total else { return slice(0..<71) + "\u{2026}" }
        let start = max(0, span.lowerBound - 24)
        let end = min(total, max(span.upperBound, start) + 44)
        return (start > 0 ? "\u{2026}" : "") + slice(start..<end) + (end < total ? "\u{2026}" : "")
    }
}

private extension SearchSubject {
    func process(where predicate: (SearchableProcess) -> Bool) -> (process: SearchableProcess, isRoot: Bool)? {
        if predicate(root) { return (root, true) }
        return helpers.first(where: predicate).map { ($0, false) }
    }
}
