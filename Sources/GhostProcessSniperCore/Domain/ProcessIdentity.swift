import Foundation
import Darwin

public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeSeconds: UInt64, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

