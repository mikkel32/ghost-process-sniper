import Foundation

/// A parsed process search.
///
/// Plain words must all match (in any order) somewhere in a process's name,
/// helper names, command line or path. On top of that:
///
/// - `"exact phrase"` keeps words together; `-word` or `!word` excludes.
/// - `name:` `cmd:` `path:` `user:` `kind:` scope a word to one field.
/// - `pid:123,456` and `port:3000` match identities; a bare number matches a
///   PID or listening port as well as text.
/// - `cpu>20` `mem>1.5gb` `gpu>=5` `leak>2` `threads>100` `children>3`
///   `watts>2` `wakeups>150` `writes>5mb` compare measurements (memory and
///   disk writes per second default to MB).
/// - `is:hot` `is:leaking` `is:killable` `is:dev` `is:system` `is:mine`
///   `is:tracked` … select radar states; any unique prefix works (`is:leak`).
public struct ProcessSearchQuery: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case any, name, command, path, user, kind

        static func named(_ key: String) -> Field? {
            switch key {
            case "name", "app", "process": .name
            case "cmd", "command", "args", "arg": .command
            case "path", "exe", "bin": .path
            case "user", "owner": .user
            case "kind", "type": .kind
            default: nil
            }
        }
    }

    public struct Term: Equatable, Sendable {
        public let text: String
        public let field: Field
        public let isNegated: Bool
        let folded: [UInt8]
        /// Set when the term is a plain number, which may also be a PID or port.
        let number: Int?
    }

    public enum Metric: String, CaseIterable, Sendable {
        case cpu, memory, gpu, leak, threads, children, energy, wakeups, writes

        static func named(_ key: String) -> Metric? {
            switch key {
            case "watts", "watt", "energy", "power": .energy
            case "wakeups", "wakes", "wake": .wakeups
            case "writes", "write", "disk": .writes
            case "cpu": .cpu
            case "mem", "memory", "ram": .memory
            case "gpu": .gpu
            case "leak", "growth": .leak
            case "threads", "thread": .threads
            case "children", "kids", "helpers": .children
            default: nil
            }
        }

        var label: String {
            switch self {
            case .cpu: "CPU"
            case .memory: "Memory"
            case .gpu: "GPU"
            case .leak: "Growth"
            case .threads: "Threads"
            case .children: "Helpers"
            case .energy: "Energy"
            case .wakeups: "Wake-ups"
            case .writes: "Disk writes"
            }
        }
    }

    public enum Comparison: String, Sendable {
        case greater = ">"
        case greaterOrEqual = ">="
        case less = "<"
        case lessOrEqual = "<="
        case equal = "="

        func holds(_ value: Double, _ reference: Double) -> Bool {
            switch self {
            case .greater: value > reference
            case .greaterOrEqual: value >= reference
            case .less: value < reference
            case .lessOrEqual: value <= reference
            case .equal: abs(value - reference) < 0.5
            }
        }
    }

    public struct MetricFilter: Equatable, Sendable {
        public let metric: Metric
        public let comparison: Comparison
        /// Percent for CPU and GPU, bytes for memory, MB/min for growth,
        /// watts for energy, per second for wake-ups, bytes per second for writes.
        public let value: Double
        public let isNegated: Bool

        func accepts(_ measured: Double?) -> Bool {
            guard let measured else { return isNegated }
            return comparison.holds(measured, value) != isNegated
        }
    }

    public enum Flag: String, CaseIterable, Sendable {
        case attention, hot, critical, quiet, leaking, killable, dev, system, mine, tracked, untracked, duplicate

        static func named(_ key: String) -> Flag? {
            switch key {
            case "stoppable", "stop": return .killable
            case "leak", "leaky": return .leaking
            case "user", "own", "owned": return .mine
            case "dup", "dupe", "duplicated": return .duplicate
            default: break
            }
            if let exact = Flag(rawValue: key) { return exact }
            let candidates = allCases.filter { $0.rawValue.hasPrefix(key) }
            return candidates.count == 1 ? candidates[0] : nil
        }

        var label: String {
            switch self {
            case .attention: "Needs attention"
            case .hot: "Hot"
            case .critical: "Critical"
            case .quiet: "Quiet"
            case .leaking: "Leaking"
            case .killable: "Can stop"
            case .dev: "Developer tool"
            case .system: "System"
            case .mine: "Mine"
            case .tracked: "Tracked"
            case .untracked: "Not tracked"
            case .duplicate: "Duplicate"
            }
        }
    }

    public struct FlagFilter: Equatable, Sendable {
        public let flag: Flag
        public let isNegated: Bool
    }

    public struct IdentityFilter: Equatable, Sendable {
        public let values: Set<Int>
        public let isNegated: Bool
    }

    /// One understood piece of the query, for the interface to echo back.
    public struct Token: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case text, field, metric, flag, identity, ignored }
        public let id: Int
        public let label: String
        public let kind: Kind
        public let isNegated: Bool
    }

    public let raw: String
    public let terms: [Term]
    public let metrics: [MetricFilter]
    public let flags: [FlagFilter]
    public let pids: [IdentityFilter]
    public let ports: [IdentityFilter]
    public let tokens: [Token]

    public static let empty = ProcessSearchQuery(raw: "")

    public var isEmpty: Bool {
        terms.isEmpty && metrics.isEmpty && flags.isEmpty && pids.isEmpty && ports.isEmpty
    }

    /// Positive words rank results; pure filters keep the chosen sort order.
    public var ranksByRelevance: Bool {
        terms.contains { !$0.isNegated } || pids.contains { !$0.isNegated } || ports.contains { !$0.isNegated }
    }

    /// True when the query can only be satisfied by radar-assessed families.
    public var requiresTrackedFamily: Bool {
        flags.contains { !$0.isNegated && $0.flag != .system && $0.flag != .mine && $0.flag != .untracked } ||
            metrics.contains { !$0.isNegated && ($0.metric == .leak || $0.metric == .children) }
    }

    public init(_ text: String) {
        self.init(raw: text)
    }

    private init(raw: String) {
        self.raw = raw
        var terms: [Term] = []
        var metrics: [MetricFilter] = []
        var flags: [FlagFilter] = []
        var pids: [IdentityFilter] = []
        var ports: [IdentityFilter] = []
        var tokens: [Token] = []

        func note(_ label: String, _ kind: Token.Kind, _ negated: Bool) {
            tokens.append(Token(id: tokens.count, label: label, kind: kind, isNegated: negated))
        }

        for token in Self.split(raw) {
            var body = token
            var negated = false
            if body.count > 1, body.first == "-" || body.first == "!" {
                negated = true
                body.removeFirst()
            }
            let quoted = body.first == "\""
            if quoted { body = Self.unquoted(body) }
            let lowered = body.lowercased()

            if !quoted, let filter = Self.metricFilter(lowered, negated: negated) {
                metrics.append(filter)
                note(Self.describe(filter), .metric, negated)
                continue
            }
            if !quoted, let colon = lowered.firstIndex(of: ":"), colon != lowered.startIndex {
                let key = String(lowered[..<colon])
                let value = Self.unquoted(String(body[body.index(after: colon)...]))
                let loweredValue = value.lowercased().trimmingCharacters(in: .whitespaces)
                if key == "is" || key == "has" {
                    if let flag = Flag.named(loweredValue) {
                        flags.append(FlagFilter(flag: flag, isNegated: negated))
                        note(flag.label, .flag, negated)
                    } else if !loweredValue.isEmpty {
                        note("Unknown filter \u{201c}is:\(loweredValue)\u{201d}", .ignored, negated)
                    }
                    continue
                }
                if key == "pid" || key == "port" {
                    let values = Set(loweredValue.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
                    if !values.isEmpty {
                        let filter = IdentityFilter(values: values, isNegated: negated)
                        let list = values.sorted().map(String.init).joined(separator: ", ")
                        if key == "pid" {
                            pids.append(filter)
                            note("PID \(list)", .identity, negated)
                        } else {
                            ports.append(filter)
                            note("Port \(list)", .identity, negated)
                        }
                    }
                    continue
                }
                if let field = Field.named(key) {
                    let folded = FoldedText(value).bytes
                    if !folded.isEmpty {
                        terms.append(Term(text: value, field: field, isNegated: negated, folded: folded, number: nil))
                        note("\(field.rawValue.capitalized): \(value)", .field, negated)
                    }
                    continue
                }
            }

            // A half-typed filter such as `cpu>` or `mem:` narrows nothing yet;
            // matching it as literal text would blank the list mid-keystroke.
            if !quoted, Self.isIncompleteMetric(lowered) { continue }

            let folded = FoldedText(body).bytes
            guard !folded.isEmpty else { continue }
            let number = quoted ? nil : Int(body)
            terms.append(Term(text: body, field: .any, isNegated: negated, folded: folded, number: number))
            note(quoted ? "\u{201c}\(body)\u{201d}" : body, .text, negated)
        }

        self.terms = terms
        self.metrics = metrics
        self.flags = flags
        self.pids = pids
        self.ports = ports
        self.tokens = tokens
    }

    /// Matches words and phrases against plain text fields; structured
    /// filters are ignored. Used by lists that are not process families.
    public func matchesText(_ fields: [String]) -> Bool {
        let folded = fields.map { FoldedText($0) }
        return matchesText(folded)
    }

    func matchesText(_ fields: [FoldedText]) -> Bool {
        for term in terms {
            let found = fields.contains { TextMatcher.literalMatch(term.folded, in: $0) != nil }
            if found == term.isNegated { return false }
        }
        return true
    }

    /// Splits on whitespace outside double quotes. Quotes stay in the token
    /// so `"phrase"`, `-"phrase"` and `key:"value"` can be told apart.
    /// macOS substitutes curly quotes while typing; treat them as straight.
    private static func split(_ raw: String) -> [String] {
        let normalized = raw
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .replacingOccurrences(of: #"\s*(>=|<=|>|<|=)\s*"#, with: "$1", options: .regularExpression)
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in normalized {
            if character == "\"" { inQuotes.toggle() }
            if character.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquoted(_ text: String) -> String {
        var text = text
        if text.first == "\"" { text.removeFirst() }
        if text.last == "\"" { text.removeLast() }
        return text
    }

    private static let metricPattern = try! NSRegularExpression(
        pattern: #"^([a-z]+):?(>=|<=|>|<|=)?([0-9]+(?:\.[0-9]+)?)\s*(%|[kmgt]i?b?(?:/s)?|b(?:/s)?|mb/min|w|/s)?$"#
    )

    private static func metricFilter(_ token: String, negated: Bool) -> MetricFilter? {
        let range = NSRange(token.startIndex..., in: token)
        guard let match = metricPattern.firstMatch(in: token, range: range),
              let keyRange = Range(match.range(at: 1), in: token),
              let metric = Metric.named(String(token[keyRange])),
              let valueRange = Range(match.range(at: 3), in: token),
              let number = Double(token[valueRange])
        else { return nil }
        let hasOperator = match.range(at: 2).location != NSNotFound
        guard hasOperator || token.contains(":") else { return nil }
        let comparison = Range(match.range(at: 2), in: token).flatMap { Comparison(rawValue: String(token[$0])) } ?? .greaterOrEqual
        let unit = Range(match.range(at: 4), in: token).map { String(token[$0]) } ?? ""
        let value: Double
        if metric == .memory || metric == .writes {
            switch unit.first {
            case "b": value = number
            case "k": value = number * 1_024
            case "g": value = number * 1_073_741_824
            case "t": value = number * 1_099_511_627_776
            default: value = number * 1_048_576
            }
        } else {
            value = number
        }
        return MetricFilter(metric: metric, comparison: comparison, value: value, isNegated: negated)
    }

    private static func isIncompleteMetric(_ token: String) -> Bool {
        guard let end = token.firstIndex(where: { ":<>=".contains($0) }) else { return false }
        return Metric.named(String(token[..<end])) != nil
    }

    private static func describe(_ filter: MetricFilter) -> String {
        let value: String
        switch filter.metric {
        case .memory: value = RadarFormat.bytes(UInt64(max(0, filter.value)))
        case .cpu, .gpu: value = "\(Self.number(filter.value))%"
        case .leak: value = "\(Self.number(filter.value)) MB/min"
        case .threads, .children: value = Self.number(filter.value)
        case .energy: value = "\(Self.number(filter.value)) W"
        case .wakeups: value = "\(Self.number(filter.value))/s"
        case .writes: value = RadarFormat.bytes(UInt64(max(0, filter.value))) + "/s"
        }
        let symbol = switch filter.comparison {
        case .greater: ">"
        case .greaterOrEqual: "\u{2265}"
        case .less: "<"
        case .lessOrEqual: "\u{2264}"
        case .equal: "="
        }
        return "\(filter.metric.label) \(symbol) \(value)"
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
