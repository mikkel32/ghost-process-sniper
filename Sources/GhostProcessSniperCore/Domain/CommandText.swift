import Foundation

/// Whitespace tests for splitting command lines on every tick. Command
/// lines are almost entirely ASCII, so the Unicode property lookup runs only
/// for the rare non-ASCII character; the answer is identical either way.
extension Character {
    var isCommandWhitespace: Bool {
        if let ascii = asciiValue { return ascii == 0x20 || (0x09...0x0D).contains(ascii) }
        return isWhitespace
    }
}

extension Unicode.Scalar {
    var isCommandWhitespace: Bool {
        if isASCII { return value == 0x20 || (0x09...0x0D).contains(value) }
        return properties.isWhitespace
    }
}
