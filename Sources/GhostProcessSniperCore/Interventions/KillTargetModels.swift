import Darwin
import Foundation

public enum KillScope: String, Codable, CaseIterable, Sendable {
    case ownedFamily
    case singleRoot
    case ownedProcessGroupPreview

    public var label: String {
        switch self {
        case .ownedFamily: "Owned family"
        case .singleRoot: "Root only"
        case .ownedProcessGroupPreview: "Process group preview"
        }
    }
}

public enum KillTargetState: String, Codable, CaseIterable, Sendable {
    case ready
    case locked
    case stale
    case recycled
    case terminated
    case forceKilled
    case survived
    case exitedBeforeSignal
    case failed

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .locked: "Locked"
        case .stale: "Stale"
        case .recycled: "Recycled"
        case .terminated: "Terminated"
        case .forceKilled: "Force killed"
        case .survived: "Survived"
        case .exitedBeforeSignal: "Exited first"
        case .failed: "Failed"
        }
    }
}

public struct KillTarget: Identifiable, Equatable, Sendable {
    public var id: String {
        "\(identity.pid)-\(identity.startTimeSeconds)-\(identity.startTimeMicroseconds)-\(state.rawValue)"
    }

    public let identity: ProcessIdentity
    public let parentPID: Int32?
    public let name: String
    public let ownerName: String
    public let depth: Int
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public let state: KillTargetState
    public let reason: String
    public let isRoot: Bool

    public var pid: Int32 { identity.pid }

    public init(
        identity: ProcessIdentity,
        parentPID: Int32?,
        name: String,
        ownerName: String,
        depth: Int,
        memoryBytes: UInt64,
        cpuPercent: Double,
        state: KillTargetState,
        reason: String,
        isRoot: Bool
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.name = name
        self.ownerName = ownerName
        self.depth = depth
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.state = state
        self.reason = reason
        self.isRoot = isRoot
    }

    public init(process: ProcessMetrics, depth: Int, state: KillTargetState, reason: String, rootIdentity: ProcessIdentity) {
        self.init(
            identity: process.identity,
            parentPID: process.parentPID,
            name: process.name,
            ownerName: process.ownerName,
            depth: depth,
            memoryBytes: process.memoryForScoringBytes,
            cpuPercent: process.cpuPercent,
            state: state,
            reason: reason,
            isRoot: process.identity == rootIdentity
        )
    }

    public init(process: KillProcessLite, depth: Int, state: KillTargetState, reason: String, rootIdentity: ProcessIdentity) {
        self.init(
            identity: process.identity,
            parentPID: process.parentPID,
            name: process.name,
            ownerName: process.ownerName,
            depth: depth,
            memoryBytes: process.memoryForScoringBytes,
            cpuPercent: process.cpuPercent,
            state: state,
            reason: reason,
            isRoot: process.identity == rootIdentity
        )
    }

    public func updating(state: KillTargetState, reason: String) -> KillTarget {
        KillTarget(
            identity: identity,
            parentPID: parentPID,
            name: name,
            ownerName: ownerName,
            depth: depth,
            memoryBytes: memoryBytes,
            cpuPercent: cpuPercent,
            state: state,
            reason: reason,
            isRoot: isRoot
        )
    }
}

public struct KillAttempt: Identifiable, Equatable, Sendable {
    public var id: String { "\(pid)-\(signal)-\(stage)" }

    public let pid: Int32
    public let signal: Int32
    public let signalName: String
    public let stage: String
    public let succeeded: Bool
    public let message: String

    public init(pid: Int32, signal: Int32, stage: String, succeeded: Bool, message: String = "") {
        self.pid = pid
        self.signal = signal
        self.signalName = KillAttempt.name(for: signal)
        self.stage = stage
        self.succeeded = succeeded
        self.message = message
    }

    private static func name(for signal: Int32) -> String {
        switch signal {
        case KillSignalPhase.quitRequest: "QUIT"
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        case SIGINT: "SIGINT"
        default: "Signal \(signal)"
        }
    }
}

public struct KillVerificationPass: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(stage)-\(Int(elapsedMilliseconds.rounded()))-\(sampledAt.timeIntervalSince1970)" }

    public let stage: String
    public let sampledAt: Date
    public let sampleMilliseconds: Double
    public let elapsedMilliseconds: Double
    public let livePIDs: [Int32]
    public let recycledPIDs: [Int32]
    public let exitedPIDs: [Int32]

    public init(
        stage: String,
        sampledAt: Date = Date(),
        sampleMilliseconds: Double = 0,
        elapsedMilliseconds: Double = 0,
        livePIDs: [Int32],
        recycledPIDs: [Int32],
        exitedPIDs: [Int32]
    ) {
        self.stage = stage
        self.sampledAt = sampledAt
        self.sampleMilliseconds = sampleMilliseconds
        self.elapsedMilliseconds = elapsedMilliseconds
        self.livePIDs = livePIDs.sorted()
        self.recycledPIDs = recycledPIDs.sorted()
        self.exitedPIDs = exitedPIDs.sorted()
    }
}

public struct KillOutcomeClassifier: Sendable {
    public init() {}

    public func classify(target: KillTarget, report: KillReport) -> KillTarget {
        if report.survivorPIDs.contains(target.pid) {
            return target.updating(state: .survived, reason: "Still alive after verification")
        }
        if report.forcedPIDs.contains(target.pid) {
            return target.updating(state: .forceKilled, reason: "Required SIGKILL")
        }
        if report.recycledPIDs.contains(target.pid) {
            return target.updating(state: .recycled, reason: "PID changed identity during kill")
        }
        if report.exitedBeforeSignalPIDs.contains(target.pid) {
            return target.updating(state: .exitedBeforeSignal, reason: "Exited before the signal landed")
        }
        if report.gracefulPIDs.contains(target.pid) {
            return target.updating(state: .terminated, reason: "Accepted graceful termination")
        }
        if report.deniedPIDs.contains(target.pid) {
            return target.updating(state: .locked, reason: "Signal denied")
        }
        if report.stalePIDs.contains(target.pid) {
            return target.updating(state: .stale, reason: "Identity disappeared")
        }
        return target.updating(state: .failed, reason: "No terminal status")
    }
}

public struct KillCollateralCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(identity.pid)-\(identity.startTimeSeconds)-\(identity.startTimeMicroseconds)" }

    public let identity: ProcessIdentity
    public let name: String
    public let processGroupID: Int32
    public let memoryBytes: UInt64
    public let reason: String

    public init(identity: ProcessIdentity, name: String, processGroupID: Int32, memoryBytes: UInt64, reason: String) {
        self.identity = identity
        self.name = name
        self.processGroupID = processGroupID
        self.memoryBytes = memoryBytes
        self.reason = reason
    }

    public init(process: KillProcessLite, reason: String) {
        self.init(
            identity: process.identity,
            name: process.name,
            processGroupID: process.processGroupID,
            memoryBytes: process.memoryForScoringBytes,
            reason: reason
        )
    }
}

public struct KillTargetDiff: Codable, Equatable, Sendable {
    public let addedPIDs: [Int32]
    public let exitedPIDs: [Int32]
    public let recycledPIDs: [Int32]
    public let reparentedPIDs: [Int32]
    public let survivorPIDs: [Int32]

    public static let empty = KillTargetDiff(addedPIDs: [], exitedPIDs: [], recycledPIDs: [], reparentedPIDs: [], survivorPIDs: [])

    public init(addedPIDs: [Int32], exitedPIDs: [Int32], recycledPIDs: [Int32], reparentedPIDs: [Int32], survivorPIDs: [Int32]) {
        self.addedPIDs = addedPIDs.sorted()
        self.exitedPIDs = exitedPIDs.sorted()
        self.recycledPIDs = recycledPIDs.sorted()
        self.reparentedPIDs = reparentedPIDs.sorted()
        self.survivorPIDs = survivorPIDs.sorted()
    }

    public var isEmpty: Bool {
        addedPIDs.isEmpty && exitedPIDs.isEmpty && recycledPIDs.isEmpty && reparentedPIDs.isEmpty && survivorPIDs.isEmpty
    }

    public var summary: String {
        if isEmpty {
            return "No target drift detected."
        }
        var parts: [String] = []
        if !addedPIDs.isEmpty { parts.append("+\(addedPIDs.count) new") }
        if !exitedPIDs.isEmpty { parts.append("\(exitedPIDs.count) exited") }
        if !recycledPIDs.isEmpty { parts.append("\(recycledPIDs.count) recycled") }
        if !reparentedPIDs.isEmpty { parts.append("\(reparentedPIDs.count) reparented") }
        if !survivorPIDs.isEmpty { parts.append("\(survivorPIDs.count) survived") }
        return parts.joined(separator: ", ")
    }
}

public struct KillGraphDelta: Codable, Equatable, Sendable {
    public let previewTargetPIDs: [Int32]
    public let confirmTargetPIDs: [Int32]
    public let finalSurvivorPIDs: [Int32]
    public let drift: KillTargetDiff

    public static let empty = KillGraphDelta(
        previewTargetPIDs: [],
        confirmTargetPIDs: [],
        finalSurvivorPIDs: [],
        drift: .empty
    )

    public init(
        previewTargetPIDs: [Int32],
        confirmTargetPIDs: [Int32],
        finalSurvivorPIDs: [Int32],
        drift: KillTargetDiff
    ) {
        self.previewTargetPIDs = previewTargetPIDs.sorted()
        self.confirmTargetPIDs = confirmTargetPIDs.sorted()
        self.finalSurvivorPIDs = finalSurvivorPIDs.sorted()
        self.drift = drift
    }

    public var summary: String {
        let added = Set(confirmTargetPIDs).subtracting(previewTargetPIDs)
        let removed = Set(previewTargetPIDs).subtracting(confirmTargetPIDs)
        if added.isEmpty, removed.isEmpty, finalSurvivorPIDs.isEmpty, drift.isEmpty {
            return "No intervention graph drift."
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("+\(added.count) confirm") }
        if !removed.isEmpty { parts.append("-\(removed.count) confirm") }
        if !finalSurvivorPIDs.isEmpty { parts.append("\(finalSurvivorPIDs.count) survivors") }
        if !drift.isEmpty { parts.append(drift.summary) }
        return parts.joined(separator: ", ")
    }
}

public struct KillScopePreview: Codable, Equatable, Sendable {
    public let scope: KillScope
    public let targetCount: Int
    public let lockedCount: Int
    public let nearbyCandidates: [KillCollateralCandidate]
    public let drift: KillTargetDiff
    public let summary: String

    public static let empty = KillScopePreview(
        scope: .ownedFamily,
        targetCount: 0,
        lockedCount: 0,
        nearbyCandidates: [],
        drift: .empty,
        summary: "No scope preview yet."
    )

    public init(
        scope: KillScope,
        targetCount: Int,
        lockedCount: Int,
        nearbyCandidates: [KillCollateralCandidate],
        drift: KillTargetDiff = .empty,
        summary: String
    ) {
        self.scope = scope
        self.targetCount = targetCount
        self.lockedCount = lockedCount
        self.nearbyCandidates = nearbyCandidates
        self.drift = drift
        self.summary = summary
    }
}
