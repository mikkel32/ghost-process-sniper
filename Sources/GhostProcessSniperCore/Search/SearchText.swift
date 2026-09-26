import Foundation

/// Text folded once for matching: case-, diacritic- and width-insensitive
/// UTF-8 with its word starts. Searching bytes keeps per-keystroke work cheap;
/// UTF-8 is self-synchronizing, so a byte match is always a scalar match.
public struct FoldedText: Equatable, Sendable {
    public static let empty = FoldedText("")

    public let bytes: [UInt8]
    /// Byte offsets that begin a word: after a separator, at a camelCase hump,
    /// or where letters turn into digits and back. Sorted ascending.
    let wordStarts: [Int]
    /// The original `Character` offset of every folded byte. Only tracked for
    /// short display text that the interface highlights.
    let characterOffsets: [Int]

    public init(_ text: String, tracksCharacters: Bool = false, maxCharacters: Int = .max) {
        var bytes: [UInt8] = []
        var wordStarts: [Int] = []
        var offsets: [Int] = []
        let capacity = min(text.utf8.count, 16_384)
        bytes.reserveCapacity(capacity)
        if tracksCharacters { offsets.reserveCapacity(capacity) }
        var previous = CharacterClass.separator
        var characterIndex = 0
        for character in text {
            guard characterIndex < maxCharacters else { break }
            let start = bytes.count
            let current: CharacterClass
            if let ascii = character.asciiValue {
                current = CharacterClass(ascii: ascii)
                bytes.append(current == .upper ? ascii + 32 : ascii)
            } else {
                current = CharacterClass(character)
                let folded = String(character).folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: nil
                )
                bytes.append(contentsOf: folded.utf8)
            }
            if current.startsWord(after: previous), bytes.count > start {
                wordStarts.append(start)
            }
            if tracksCharacters {
                for _ in start..<bytes.count { offsets.append(characterIndex) }
            }
            previous = current
            characterIndex += 1
        }
        self.bytes = bytes
        self.wordStarts = wordStarts
        self.characterOffsets = offsets
    }

    public var isEmpty: Bool { bytes.isEmpty }

    func isWordStart(_ offset: Int) -> Bool {
        var low = 0
        var high = wordStarts.count
        while low < high {
            let middle = (low + high) / 2
            if wordStarts[middle] < offset { low = middle + 1 } else { high = middle }
        }
        return low < wordStarts.count && wordStarts[low] == offset
    }

    /// Converts matched byte offsets into merged original-character ranges.
    func characterRanges(for byteOffsets: [Int]) -> [Range<Int>] {
        guard !characterOffsets.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        for offset in byteOffsets where offset < characterOffsets.count {
            let character = characterOffsets[offset]
            if let last = ranges.last, character <= last.upperBound {
                if character == last.upperBound { ranges[ranges.count - 1] = last.lowerBound..<(character + 1) }
            } else {
                ranges.append(character..<(character + 1))
            }
        }
        return ranges
    }
}

private enum CharacterClass: Equatable {
    case lower, upper, digit, separator

    init(ascii: UInt8) {
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): self = .lower
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): self = .upper
        case UInt8(ascii: "0")...UInt8(ascii: "9"): self = .digit
        default: self = .separator
        }
    }

    init(_ character: Character) {
        if character.isNumber {
            self = .digit
        } else if character.isLetter {
            self = character.isUppercase ? .upper : .lower
        } else {
            self = .separator
        }
    }

    func startsWord(after previous: CharacterClass) -> Bool {
        switch (previous, self) {
        case (_, .separator): false
        case (.separator, _): true
        case (.lower, .upper): true
        case (.digit, .lower), (.digit, .upper): true
        case (.lower, .digit), (.upper, .digit): true
        default: false
        }
    }
}

/// How well a term matched one field, best first.
public enum SearchMatchQuality: Int, Comparable, Sendable {
    case typo = 1
    case fuzzy
    case substring
    case wordStart
    case prefix
    case exact

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var weight: Double {
        switch self {
        case .exact: 1.0
        case .prefix: 0.9
        case .wordStart: 0.78
        case .substring: 0.6
        case .fuzzy: 0.42
        case .typo: 0.38
        }
    }
}

struct TextMatch: Equatable, Sendable {
    let quality: SearchMatchQuality
    /// Folded byte offsets that matched, for highlighting and snippets.
    let byteOffsets: [Int]
    /// Extra adjustment inside a quality tier (compactness of a fuzzy match).
    let bonus: Double

    var score: Double { quality.weight + bonus }
}

enum TextMatcher {
    /// Matches a folded term against folded text. `fuzzy` adds acronym,
    /// subsequence and typo matching. Callers use it only for name fields and
    /// only once literal matching found nothing: close guesses are welcome
    /// when nothing else matches and noise when something does.
    static func match(_ term: [UInt8], in text: FoldedText, fuzzy: Bool) -> TextMatch? {
        guard !term.isEmpty, !text.bytes.isEmpty else { return nil }
        if let literal = literalMatch(term, in: text) { return literal }
        guard fuzzy, term.count >= 2 else { return nil }
        if let subsequence = subsequenceMatch(term, in: text) { return subsequence }
        return typoMatch(term, in: text)
    }

    static func literalMatch(_ term: [UInt8], in text: FoldedText) -> TextMatch? {
        let bytes = text.bytes
        guard term.count <= bytes.count else { return nil }
        var firstSubstring: Int?
        var searchFrom = 0
        var inspected = 0
        while inspected < 64, let offset = firstIndex(of: term, in: bytes, from: searchFrom) {
            inspected += 1
            if offset == 0 {
                let quality: SearchMatchQuality = term.count == bytes.count ? .exact : .prefix
                return TextMatch(quality: quality, byteOffsets: Array(0..<term.count), bonus: 0)
            }
            if text.isWordStart(offset) {
                return TextMatch(quality: .wordStart, byteOffsets: Array(offset..<(offset + term.count)), bonus: 0)
            }
            if firstSubstring == nil { firstSubstring = offset }
            searchFrom = offset + 1
        }
        guard let offset = firstSubstring else { return nil }
        return TextMatch(quality: .substring, byteOffsets: Array(offset..<(offset + term.count)), bonus: 0)
    }

    static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        let count = needle.count
        guard count > 0, start >= 0, haystack.count - start >= count else { return nil }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                let first = pin[0]
                var index = start
                let last = hay.count - count
                while index <= last {
                    if hay[index] == first {
                        var matched = 1
                        while matched < count, hay[index + matched] == pin[matched] { matched += 1 }
                        if matched == count { return index }
                    }
                    index += 1
                }
                return nil
            }
        }
    }

    /// Acronyms first ("vsc" → Visual Studio Code), then a compact, in-order
    /// subsequence anchored at a word start ("chrmhlp" → Chrome Helper).
    static func subsequenceMatch(_ term: [UInt8], in text: FoldedText) -> TextMatch? {
        let bytes = text.bytes
        var acronym: [Int] = []
        var nextStart = 0
        for byte in term {
            guard let hit = text.wordStarts[nextStart...].firstIndex(where: { bytes[$0] == byte }) else {
                acronym.removeAll()
                break
            }
            acronym.append(text.wordStarts[hit])
            nextStart = hit + 1
        }
        if acronym.count == term.count {
            return TextMatch(quality: .fuzzy, byteOffsets: acronym, bonus: 0.12)
        }
        guard term.count >= 3 else { return nil }

        for anchor in text.wordStarts where bytes[anchor] == term[0] {
            var positions = [anchor]
            var cursor = anchor + 1
            for byte in term.dropFirst() {
                while cursor < bytes.count, bytes[cursor] != byte { cursor += 1 }
                guard cursor < bytes.count else { break }
                positions.append(cursor)
                cursor += 1
            }
            guard positions.count == term.count else { continue }
            let span = positions[positions.count - 1] - anchor + 1
            guard span <= term.count * 3 + 2 else { continue }
            let atStarts = positions.filter(text.isWordStart).count
            let bonus = 0.08 * Double(term.count) / Double(span) + 0.04 * Double(atStarts) / Double(term.count)
            return TextMatch(quality: .fuzzy, byteOffsets: positions, bonus: bonus)
        }
        return nil
    }

    /// One slip (two for long terms) against the start of any word that
    /// begins with the same letter: "crhome" and "spotfy" still find Chrome
    /// and Spotify, while "node" never turns into "code".
    static func typoMatch(_ term: [UInt8], in text: FoldedText) -> TextMatch? {
        guard term.count >= 4 else { return nil }
        let bytes = text.bytes
        let allowed = term.count >= 8 ? 2 : 1
        var best: (distance: Int, start: Int, length: Int)?
        for start in text.wordStarts where bytes[start] == term[0] {
            for length in max(1, term.count - allowed)...(term.count + allowed) {
                guard start + length <= bytes.count else { break }
                let distance = editDistance(term, bytes[start..<(start + length)], limit: allowed)
                if distance <= allowed, best.map({ distance < $0.distance }) ?? true {
                    best = (distance, start, length)
                }
            }
            if best?.distance == 1 && allowed == 1 { break }
        }
        guard let best else { return nil }
        return TextMatch(quality: .typo, byteOffsets: Array(best.start..<(best.start + best.length)), bonus: 0)
    }

    /// Optimal string alignment distance with an early exit above `limit`.
    static func editDistance(_ lhs: [UInt8], _ rhs: ArraySlice<UInt8>, limit: Int) -> Int {
        let right = Array(rhs)
        guard !lhs.isEmpty, !right.isEmpty else { return max(lhs.count, right.count) }
        let width = right.count + 1
        var previousPrevious = [Int](repeating: 0, count: width)
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: width)
        for i in 1...lhs.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1..<width {
                let cost = lhs[i - 1] == right[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, lhs[i - 1] == right[j - 2], lhs[i - 2] == right[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previousPrevious, &previous)
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
