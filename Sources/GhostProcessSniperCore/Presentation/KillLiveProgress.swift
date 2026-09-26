import Foundation

/// A graceful wait the user can watch: it ends when every target exits, or
/// at the deadline.
public struct KillGraceWait: Equatable, Sendable {
    public let startedAt: Date
    public let deadline: Date

    public var seconds: TimeInterval { deadline.timeIntervalSince(startedAt) }
    /// Short waits pass before an indicator could be read; showing one
    /// would only flash.
    public var showsIndicator: Bool { seconds >= 2 }
}

public enum KillLivePhase: Equatable, Sendable {
    case starting
    case stopping
    case waiting
    case verifying
    case forcing(Int)
    case holding
    case done
}

/// What a running stop shows: one reducer over the ordered event stream, so
/// the sheet keeps a single value instead of parallel dictionaries.
public struct KillLiveProgress: Equatable, Sendable {
    public static let recentEventLimit = 6

    public private(set) var phase: KillLivePhase = .starting
    public private(set) var wait: KillGraceWait?
    public private(set) var recentEvents: [KillOperationEvent] = []
    public private(set) var targetStates: [Int32: KillTargetState] = [:]
    public private(set) var reasons: [Int32: String] = [:]

    private let displayName: String
    private let kind: KillWorkloadKind
    private let strategy: KillStrategy

    public init(displayName: String, kind: KillWorkloadKind, strategy: KillStrategy) {
        self.displayName = displayName
        self.kind = kind
        self.strategy = strategy
    }

    public init(preview: KillPreview) {
        self.init(displayName: preview.displayName, kind: preview.riskAssessment.kind,
                  strategy: preview.strategyRecommendation.strategy)
    }

    public mutating func apply<Events: Sequence>(_ events: Events) where Events.Element == KillOperationEvent {
        for event in events {
            apply(event)
        }
    }

    public mutating func apply(_ event: KillOperationEvent) {
        recentEvents.append(event)
        if recentEvents.count > Self.recentEventLimit {
            recentEvents.removeFirst(recentEvents.count - Self.recentEventLimit)
        }
        if let pid = event.pid, let state = event.targetState {
            targetStates[pid] = state
            reasons[pid] = event.message
        }
        switch event.kind {
        case .queued, .preflight:
            break
        case .targetUpdated:
            // Exits during a wait are what the wait is for; it goes on.
            if wait == nil, phase == .starting { phase = .stopping }
        case .signaled:
            wait = nil
            // Each SIGKILL of the force stage is one process that ignored
            // the polite request.
            if case .forcing(let count) = phase {
                if event.signalName == "SIGKILL" { phase = .forcing(count + 1) }
            } else {
                phase = .stopping
            }
        case .graceWaiting:
            phase = .waiting
            // Measured back from the deadline: both come from the killer's
            // clock, while `createdAt` is the wall clock.
            wait = event.deadline.map { deadline in
                let start = event.waitSeconds.map { deadline.addingTimeInterval(-max(0, $0)) } ?? min(event.createdAt, deadline)
                return KillGraceWait(startedAt: start, deadline: deadline)
            }
        case .verified:
            wait = nil
            phase = .verifying
        case .forcePending:
            wait = nil
            phase = .forcing(0)
        case .forceSkipped:
            wait = nil
            phase = .holding
        case .completed, .failed:
            wait = nil
            phase = .done
        }
    }

    /// The phase without the force stage's running count: a new stage is
    /// worth announcing, each further forced process is not.
    public var stage: KillLivePhase {
        if case .forcing = phase { return .forcing(0) }
        return phase
    }

    public var headline: String {
        switch phase {
        case .starting:
            "Checking \(displayName) one last time\u{2026}"
        case .stopping:
            strategy == .quitApp ? "Asked \(displayName) to quit, like \u{2318}Q\u{2026}" : "Asking \(displayName) to stop\u{2026}"
        case .waiting:
            waitingText
        case .verifying:
            "Checking what is still running\u{2026}"
        case .forcing(let count):
            count == 1
                ? "1 process ignored the request; force-stopping it\u{2026}"
                : count > 1 ? "\(count) processes ignored the request; force-stopping them\u{2026}" : "Force-stopping what is left\u{2026}"
        case .holding:
            "Not forcing anything; noting what is still running\u{2026}"
        case .done:
            "Finishing up\u{2026}"
        }
    }

    private var waitingText: String {
        if kind == .dataStore { return "Waiting for \(displayName) to shut down cleanly\u{2026}" }
        if kind == .containerRuntime { return "Waiting for \(displayName) to shut down\u{2026}" }
        return strategy == .quitApp ? "Waiting for \(displayName) to quit\u{2026}" : "Waiting for \(displayName) to exit\u{2026}"
    }

    /// The preview's rows with what the stop has done to each so far.
    public func rows(for targets: [KillTarget]) -> [KillTarget] {
        targets.map { target in
            guard let state = targetStates[target.pid] else { return target }
            return target.updating(state: state, reason: reasons[target.pid] ?? target.reason)
        }
    }

    /// A plain label for an event in the recent steps list.
    public static func phaseText(for kind: KillOperationEventKind) -> String {
        switch kind {
        case .queued: "Started"
        case .preflight: "Checked"
        case .targetUpdated: "Update"
        case .signaled: "Asked"
        case .graceWaiting: "Waiting"
        case .forcePending: "Forcing"
        case .forceSkipped: "Held"
        case .verified: "Verified"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }
}
