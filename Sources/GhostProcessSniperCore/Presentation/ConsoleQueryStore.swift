import Foundation
import Observation

public struct ConsoleProjectionRequest: Sendable {
    public let source: RadarConsoleSnapshot
    public let incidents: [RadarIncident]
    public let state: RadarConsoleState

    public init(source: RadarConsoleSnapshot, incidents: [RadarIncident], state: RadarConsoleState) {
        self.source = source
        self.incidents = incidents
        self.state = state
    }
}

public protocol ConsoleProjecting: Sendable {
    func project(_ request: ConsoleProjectionRequest) async throws -> ConsoleDerivedSnapshot
}

/// Sorting, filtering, formatting and sidebar partitioning run on this actor,
/// never as a side effect of reading a SwiftUI view's body.
public actor ConsoleProjectionWorker: ConsoleProjecting {
    private var cache = ConsoleDerivedSnapshotCache()

    public init() {}

    public func project(_ request: ConsoleProjectionRequest) throws -> ConsoleDerivedSnapshot {
        try Task.checkCancellation()
        let result = cache.update(snapshot: request.source, incidents: request.incidents, state: request.state)
        try Task.checkCancellation()
        return result
    }
}

/// Owns the last complete presentation. Late or cancelled queries cannot
/// replace a newer result. Keeping the previous result avoids blank-list flashes.
@MainActor
@Observable
public final class ConsoleQueryStore {
    public private(set) var snapshot: ConsoleDerivedSnapshot = .empty
    public private(set) var isUpdating = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let projector: any ConsoleProjecting

    public init(projector: any ConsoleProjecting = ConsoleProjectionWorker()) {
        self.projector = projector
    }

    @discardableResult
    public func update(_ request: ConsoleProjectionRequest) async -> Bool {
        guard !Task.isCancelled else { return false }
        generation &+= 1
        let ticket = generation
        isUpdating = true
        errorMessage = nil
        do {
            let result = try await projector.project(request)
            guard ticket == generation else { return false }
            guard !Task.isCancelled else { isUpdating = false; return false }
            snapshot = result
            isUpdating = false
            return true
        } catch {
            guard ticket == generation else { return false }
            isUpdating = false
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            return false
        }
    }

    public func cancel() {
        generation &+= 1
        isUpdating = false
    }
}
