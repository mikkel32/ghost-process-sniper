import Foundation
@testable import GhostProcessSniperCore

/// Listening ports per PID from a script; a PID mapped to nil cannot be
/// read. Records which PIDs were probed, in order.
final class FakeListeningPortProbe: ListeningPortProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [Int32: Set<Int>?]
    private var probed: [Int32] = []

    init(_ answers: [Int32: Set<Int>?] = [:]) {
        self.answers = answers
    }

    var probedPIDs: [Int32] { lock.withLock { probed } }

    func ports(pid: Int32) -> Set<Int>? {
        lock.withLock { probed.append(pid) }
        if let answer = answers[pid] { return answer }
        return []
    }
}
