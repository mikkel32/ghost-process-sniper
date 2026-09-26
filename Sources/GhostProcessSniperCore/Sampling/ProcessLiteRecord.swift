import Darwin
import Foundation

public struct ProcessLiteRecord: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let name: String
    public let processGroupID: Int32
    public let status: UInt32
    public let flags: UInt32
    public let openFileCount: Int
    public let sampledAt: Date

    public var pid: Int32 { identity.pid }
    public var isSystemProcess: Bool { (flags & UInt32(PROC_FLAG_SYSTEM)) != 0 }

    public init(
        identity: ProcessIdentity,
        parentPID: Int32,
        userID: UInt32,
        name: String,
        processGroupID: Int32,
        status: UInt32,
        flags: UInt32,
        openFileCount: Int,
        sampledAt: Date
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.processGroupID = processGroupID
        self.status = status
        self.flags = flags
        self.openFileCount = openFileCount
        self.sampledAt = sampledAt
    }
}
