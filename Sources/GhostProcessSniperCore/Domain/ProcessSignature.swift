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

    private static func normalizedCommand(_ command: String) -> String {
        command
            .split(whereSeparator: \.isWhitespace)
            .map { piece in
                let text = String(piece)
                if text.hasPrefix("/var/folders/") || text.hasPrefix("/private/var/folders/") {
                    return "<tmp>"
                }
                if text.range(of: #"^\d+$"#, options: .regularExpression) != nil {
                    return "<num>"
                }
                return text
            }
            .prefix(12)
            .joined(separator: " ")
            .lowercased()
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

