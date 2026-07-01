import AppKit
import GhostProcessSniperCore
import Observation

@MainActor
@Observable
final class RadarConsoleSession {
    let monitor: ProcessMonitor
    let killer: ProcessKiller

    var state: RadarConsoleState = .default
    var pendingKill: PendingKill?
    var toast: RadarToast?
    var searchFocusToken = 0
    private(set) var isRefreshing = false
    private(set) var refreshCostHistory: [Double] = []
    private(set) var memoryPulse: [MemoryPulseSample] = []

    @ObservationIgnored private let commands = RadarCommandCoordinator()
    @ObservationIgnored private var derivedCache = ConsoleDerivedSnapshotCache()
    @ObservationIgnored private var lastFocusedFamilySignatures: Set<String> = []

    init(monitor: ProcessMonitor, killer: ProcessKiller) {
        self.monitor = monitor
        self.killer = killer
    }

    var selectedFamily: ProcessFamily? {
        commands.selectedFamily(selection: state.focusedSelection, families: monitor.families)
    }

    var selectedDetail: FamilyDetailViewModel? {
        guard let familyKey = state.focusedSelection.familyKey else {
            return nil
        }
        return monitor.detailViewModel(signatureID: familyKey)
    }

    var selectedPanel: FamilyDetailPanelModel? {
        currentDerivedSnapshot().selectedPanel
    }

    var selectedCompactDetail: CompactFamilyDetailModel? {
        currentDerivedSnapshot().selectedCompactDetail
    }

    var familyItems: [FamilyTriageViewModel] {
        currentDerivedSnapshot().familyRows
    }

    var compactFamilyItems: [CompactSidebarRowModel] {
        currentDerivedSnapshot().compactFamilyRows
    }

    var incidentItems: [RadarIncident] {
        state.incidentQuery.apply(to: monitor.incidents)
    }

    var incidentRows: [IncidentRowViewModel] {
        currentDerivedSnapshot().incidentRows
    }

    var duplicateRows: [DuplicateClusterViewModel] {
        currentDerivedSnapshot().duplicateRows
    }

    var ruleRows: [RuleRowViewModel] {
        monitor.consoleSnapshot.ruleRows
    }

    var engine: EngineDiagnosticsViewModel {
        monitor.engineDiagnostics
    }

    var engineStatus: EngineStatusSnapshot {
        monitor.engineStatus
    }

    var commandCenter: OverviewCommandCenterModel {
        monitor.consoleSnapshot.compact.commandCenter
    }

    var compactSnapshot: CompactConsoleSnapshot {
        monitor.consoleSnapshot.compact
    }

    var sidebarSections: [ConsoleSidebarSection] {
        currentDerivedSnapshot().sidebarSections
    }

    var compactSidebarSections: [CompactSidebarSection] {
        currentDerivedSnapshot().compactSidebarSections
    }

    var snapshotContentToken: SnapshotContentRevision {
        monitor.consoleSnapshot.contentRevision
    }

    func availability(_ command: RadarCommand) -> RadarCommandAvailability {
        commands.availability(
            for: command,
            selection: state.focusedSelection,
            families: monitor.families
        )
    }

    func refresh() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        Task {
            let started = Date()
            await monitor.refresh()
            // Hold the scanning indicator long enough to be perceptible.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.7 {
                try? await Task.sleep(nanoseconds: UInt64((0.7 - elapsed) * 1_000_000_000))
            }
            isRefreshing = false
        }
    }

    func recordEngineSample() {
        refreshCostHistory.append(monitor.performanceMetrics.lastRefresh.totalMilliseconds)
        if refreshCostHistory.count > 60 {
            refreshCostHistory.removeFirst(refreshCostHistory.count - 60)
        }
        // Pulse points every few seconds are plenty for a 5-minute strip and
        // keep the chart from rebuilding on every refresh tick.
        let now = Date()
        if let last = memoryPulse.last, now.timeIntervalSince(last.date) < 4 {
            return
        }
        memoryPulse.append(MemoryPulseSample(date: now, trackedBytes: monitor.summary.totalMemoryBytes))
        if memoryPulse.count > 120 {
            memoryPulse.removeFirst(memoryPulse.count - 120)
        }
    }

    private func currentDerivedSnapshot() -> ConsoleDerivedSnapshot {
        let key = ConsoleDerivedSnapshotKey(snapshot: monitor.consoleSnapshot, state: state)
        if let cached = derivedCache.cached(snapshot: monitor.consoleSnapshot, state: state), cached.key == key {
            return cached
        }
        return derivedCache.update(
            snapshot: monitor.consoleSnapshot,
            incidents: monitor.incidents,
            state: state
        )
    }

    func toggleInspector() {
        state.showInspector.toggle()
    }

    func nextFamily() {
        state.focusedSelection = monitor.familySelection(after: state.focusedSelection, direction: 1)
        updateFocusedFamilies()
    }

    func previousFamily() {
        state.focusedSelection = monitor.familySelection(after: state.focusedSelection, direction: -1)
        updateFocusedFamilies()
    }

    func focus(_ selection: RadarFocusedSelection) {
        state.focusedSelection = selection
        updateFocusedFamilies()
    }

    func updateFocusedFamilies() {
        var signatures = Set(compactFamilyItems.prefix(8).map(\.signature.id))
        if let selected = selectedFamily {
            signatures.insert(selected.signature.id)
        }
        guard signatures != lastFocusedFamilySignatures else {
            return
        }
        lastFocusedFamilySignatures = signatures
        monitor.focusFamilies(signatureIDs: signatures)
    }

    func showToast(_ message: String, systemImage: String = "checkmark.circle") {
        toast = RadarToast(message: message, systemImage: systemImage)
    }

    func requestSearchFocus() {
        searchFocusToken += 1
    }

    func copyReport() {
        Task {
            let report = await monitor.exportIncidentReport()
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                showToast("Incident report copied", systemImage: "doc.on.clipboard")
            }
        }
    }

    func copyDiagnostics() {
        Task {
            let report = await monitor.exportDiagnosticsReport()
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                showToast("Diagnostics copied", systemImage: "stethoscope")
            }
        }
    }

    func copyDuplicateReport(_ row: DuplicateClusterViewModel) {
        let detail = DuplicateClusterDetailModel(cluster: row.cluster)
        let report = [
            "Ghost Process Sniper Duplicate Cluster",
            "Name: \(detail.title)",
            "Key: \(detail.keyText)",
            "Reason: \(detail.captureReason)",
            "Kind: \(row.kindText)",
            "Instances: \(row.countText), independent roots: \(row.rootCountText)",
            "Memory: \(row.memoryText), CPU: \(row.cpuText)",
            "PIDs: \(row.pidText)",
            "Commands:",
            detail.commandHints.isEmpty ? "  none" : detail.commandHints.map { "  \($0)" }.joined(separator: "\n"),
            "Paths:",
            detail.pathHints.isEmpty ? "  none" : detail.pathHints.map { "  \($0)" }.joined(separator: "\n"),
            "Related families:",
            detail.relatedFamilyKeys.isEmpty ? "  none" : detail.relatedFamilyKeys.map { "  \($0)" }.joined(separator: "\n")
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        showToast("Duplicate report copied", systemImage: "doc.on.clipboard")
    }

    func snoozeSelected(minutes: TimeInterval = 60) {
        guard let signatureID = selectedFamily?.signature.id ?? state.focusedSelection.signatureID else {
            return
        }
        snooze(familyKey: signatureID, name: selectedFamily?.displayName, minutes: minutes)
    }

    func ignoreSelected() {
        guard let signatureID = selectedFamily?.signature.id ?? state.focusedSelection.signatureID else {
            return
        }
        ignore(familyKey: signatureID, name: selectedFamily?.displayName)
    }

    func snooze(familyKey: String, name: String? = nil, minutes: TimeInterval = 60) {
        Task { await monitor.snooze(signatureID: familyKey, minutes: minutes) }
        showToast("Snoozed \(name ?? "family") for \(Self.durationText(minutes: minutes))", systemImage: "moon")
    }

    func ignore(familyKey: String, name: String? = nil) {
        Task { await monitor.ignore(signatureID: familyKey) }
        showToast("Ignoring \(name ?? "family") — undo under Rules", systemImage: "eye.slash")
    }

    func prepareKillSelected() {
        guard let family = selectedFamily else {
            return
        }
        prepareKill(family)
    }

    func prepareKill(familyKey: String) {
        guard let family = monitor.family(signatureID: familyKey) else {
            return
        }
        prepareKill(family)
    }

    static func durationText(minutes: TimeInterval) -> String {
        if minutes < 60 {
            return "\(Int(minutes)) min"
        }
        let hours = minutes / 60
        return hours == hours.rounded() ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
    }

    func prepareKill(_ family: ProcessFamily) {
        Task {
            let preview = await monitor.previewKill(family: family, killer: killer)
            await MainActor.run {
                pendingKill = PendingKill(family: family, preview: preview)
            }
        }
    }

    func confirmKill(
        _ pending: PendingKill,
        skipForce: Bool = false,
        control: KillOperationControl? = nil,
        eventSink: (@Sendable (KillOperationEvent) -> Void)? = nil
    ) async -> KillReport {
        await monitor.confirmKill(
            family: pending.family,
            killer: killer,
            skipForce: skipForce,
            control: control,
            eventSink: eventSink
        )
    }
}

struct PendingKill: Identifiable {
    let family: ProcessFamily
    let preview: KillPreview

    var id: String {
        family.familyKey
    }
}

struct RadarToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let systemImage: String
}

struct MemoryPulseSample: Identifiable, Equatable {
    let date: Date
    let trackedBytes: UInt64

    var id: Date {
        date
    }
}
