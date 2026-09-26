import Foundation
import Darwin

public struct ProcessForensics: Codable, Equatable, Sendable {
    public let currentDirectory: String?
    public let rootDirectory: String?
    public let openFileCount: Int?
    public let socketCount: Int?
    public let listeningPorts: [Int]
    public let isPartial: Bool
    public let notes: [String]

    public static func unavailable(reason: String) -> ProcessForensics {
        ProcessForensics(
            currentDirectory: nil,
            rootDirectory: nil,
            openFileCount: nil,
            socketCount: nil,
            listeningPorts: [],
            isPartial: true,
            notes: [reason]
        )
    }

    public init(
        currentDirectory: String?,
        rootDirectory: String?,
        openFileCount: Int?,
        socketCount: Int?,
        listeningPorts: [Int],
        isPartial: Bool,
        notes: [String]
    ) {
        self.currentDirectory = currentDirectory
        self.rootDirectory = rootDirectory
        self.openFileCount = openFileCount
        self.socketCount = socketCount
        self.listeningPorts = listeningPorts
        self.isPartial = isPartial
        self.notes = notes
    }
}

