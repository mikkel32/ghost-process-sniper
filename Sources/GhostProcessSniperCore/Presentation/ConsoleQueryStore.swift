import Foundation
import Observation

public struct ConsoleProjectionRequest: Sendable {
    public let source: RadarConsoleSnapshot
    public let incidents: [RadarIncident]
    public let state: RadarConsoleState
    /// Tracked families with their helpers, so a search reaches helper names
    /// and command lines, not only what the row displays.
    public let families: [ProcessFamily]
    /// Every process in the latest sample, tracked or not.
    public let processes: [ProcessMetrics]
    public let sampleRevision: UInt64

    public init(
        source: RadarConsoleSnapshot,
        incidents: [RadarIncident],
        state: RadarConsoleState,
        families: [ProcessFamily] = [],
        processes: [ProcessMetrics] = [],
        sampleRevision: UInt64 = 0
    ) {
        self.source = source
        self.incidents = incidents
        self.state = state
        self.families = families
        self.processes = processes
        self.sampleRevision = sampleRevision
    }
}

public protocol ConsoleProjecting: Sendable {
    func project(_ request: ConsoleProjectionRequest) async throws -> ConsoleDerivedSnapshot
    /// The detail panel for any family in the request, prepared or not.
    func panel(familyKey: String, request: ConsoleProjectionRequest) async throws -> FamilyDetailPanelModel?
}

/// Sorting, filtering, formatting and sidebar partitioning run on this actor,
/// never as a side effect of reading a SwiftUI view's body.
public actor ConsoleProjectionWorker: ConsoleProjecting {
    private var cache = ConsoleDerivedSnapshotCache()
    private var panelCache: (key: PanelKey, panel: FamilyDetailPanelModel?)?
    public private(set) var panelBuildCount = 0

    private struct PanelKey: Equatable {
        let familyKey: String
        let contentRevision: SnapshotContentRevision
        let sampleRevision: UInt64
    }

    public init() {}

    public func project(_ request: ConsoleProjectionRequest) throws -> ConsoleDerivedSnapshot {
        try Task.checkCancellation()
        let result = cache.update(request)
        try Task.checkCancellation()
        return result
    }

    /// Panels the refresh prepared come straight from the snapshot. Any other
    /// family is built here, off the main actor, as soon as it is selected
    /// instead of on the next refresh.
    public func panel(familyKey: String, request: ConsoleProjectionRequest) throws -> FamilyDetailPanelModel? {
        if let prepared = request.source.detailPanel(for: familyKey) {
            return prepared
        }
        let key = PanelKey(familyKey: familyKey, contentRevision: request.source.contentRevision, sampleRevision: request.sampleRevision)
        if let panelCache, panelCache.key == key {
            return panelCache.panel
        }
        try Task.checkCancellation()
        panelBuildCount += 1
        let previous = panelCache?.key.familyKey == familyKey ? panelCache?.panel : nil
        let panel = Self.buildPanel(familyKey: familyKey, request: request, reusing: previous)
        panelCache = (key, panel)
        return panel
    }

    static func buildPanel(
        familyKey: String,
        request: ConsoleProjectionRequest,
        reusing previous: FamilyDetailPanelModel? = nil
    ) -> FamilyDetailPanelModel? {
        if let prepared = request.source.detailPanel(for: familyKey) {
            return prepared
        }
        guard let family = request.families.first(where: { $0.familyKey == familyKey }) else {
            return nil
        }
        // The panel follows every sample; the stop assessment only changes
        // with the process tree.
        if let previous, let risk = previous.stopRisk,
           previous.workloadKey == FamilyDetailPanelModel.workloadKey(for: family) {
            return FamilyDetailPanelModel(family: family, stopRisk: risk)
        }
        let processesByPID = Dictionary(request.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return FamilyDetailPanelModel(family: family, processesByPID: processesByPID)
    }
}

/// Owns the last complete presentation. Late or cancelled queries cannot
/// replace a newer result. Keeping the previous result avoids blank-list flashes.
@MainActor
@Observable
public final class ConsoleQueryStore {
    public private(set) var snapshot: ConsoleDerivedSnapshot = .empty
    /// The selected family's panel when the refresh did not prepare one.
    public private(set) var selectedPanel: FamilyDetailPanelModel?
    public private(set) var isUpdating = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var panelGeneration: UInt64 = 0
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

    /// Shows a synchronously built projection at once, so a console that just
    /// opened never draws empty lists, and retires any older projection still
    /// in flight so it cannot overwrite the seed.
    public func seed(_ snapshot: ConsoleDerivedSnapshot) {
        guard snapshot.key != self.snapshot.key else { return }
        generation &+= 1
        isUpdating = false
        self.snapshot = snapshot
    }

    /// Same publication rules as `update`: only the newest request may
    /// replace the panel.
    @discardableResult
    public func updatePanel(familyKey: String, request: ConsoleProjectionRequest) async -> Bool {
        guard !Task.isCancelled else { return false }
        panelGeneration &+= 1
        let ticket = panelGeneration
        do {
            let panel = try await projector.panel(familyKey: familyKey, request: request)
            guard ticket == panelGeneration, !Task.isCancelled else { return false }
            if selectedPanel != panel {
                selectedPanel = panel
            }
            return true
        } catch {
            return false
        }
    }

    public func cancel() {
        generation &+= 1
        panelGeneration &+= 1
        isUpdating = false
    }
}
