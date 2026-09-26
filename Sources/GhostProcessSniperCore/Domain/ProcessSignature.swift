import Foundation
import Darwin

public struct ProcessSignature: Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let canonicalPath: String
    public let commandFingerprint: String

    public init(displayName: String, canonicalPath: String, commandLine: String) {
        let normalizedCommand = ProcessSignature.normalizedCommand(commandLine)
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.commandFingerprint = ProcessSignature.fingerprint(normalizedCommand)
        self.id = [
            displayName.lowercased(),
            canonicalPath.lowercased(),
            commandFingerprint
        ].joined(separator: "|")
    }

    public init(id: String, displayName: String, canonicalPath: String, commandFingerprint: String) {
        self.id = id
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.commandFingerprint = commandFingerprint
    }

    public static func from(root: ProcessMetrics) -> ProcessSignature {
        let path = root.executablePath.isEmpty ? root.name : root.executablePath
        return ProcessSignature(
            displayName: root.name,
            canonicalPath: path,
            commandLine: root.commandLine
        )
    }

    // Bounded before the per-token work: command lines with hundreds of
    // arguments used to normalize every token only to keep twelve.
    private static func normalizedCommand(_ command: String) -> String {
        command
            .split(whereSeparator: \.isWhitespace)
            .prefix(12)
            .map { piece -> String in
                if piece.hasPrefix("/var/folders/") || piece.hasPrefix("/private/var/folders/") {
                    return "<tmp>"
                }
                if isDecimalDigits(piece) {
                    return "<num>"
                }
                return String(piece)
            }
            .joined(separator: " ")
            .lowercased()
    }

    /// The regex `^\d+$` this replaced: every scalar a decimal digit, which
    /// includes non-ASCII digits such as Arabic-Indic and full-width ones.
    static func isDecimalDigits(_ token: Substring) -> Bool {
        guard !token.isEmpty else { return false }
        for scalar in token.unicodeScalars {
            if scalar.isASCII {
                guard scalar.value >= 48, scalar.value <= 57 else { return false }
            } else if scalar.properties.generalCategory != .decimalNumber {
                return false
            }
        }
        return true
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

