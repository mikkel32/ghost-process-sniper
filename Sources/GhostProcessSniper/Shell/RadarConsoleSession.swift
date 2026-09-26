import AppKit
import GhostProcessSniperCore
import Observation

@MainActor
@Observable
final class RadarConsoleSession {
    let monitor: ProcessMonitor
    let killer: ProcessKiller
    let openSettings: () -> Void
    let queries = ConsoleQueryStore()
    private(set) var navigationSubtitle = "Monitoring"

    var state = RadarConsoleViewState()
    var pendingKill: PendingKill?
    var toast: RadarToast?
    var searchFocusToken = 0
    var familyQueryResetToken = 0
    var showQuickGuide = false
    private(set) var hasNavigationIntent = false
    private(set) var isRefreshing = false
    private(set) var refreshCostHistory: [RefreshCostSample] = []
    private(set) var memoryPulse: [MemoryPulseSample] = []
    private(set) var thermalHistory = ThermalTraceHistory()

    @ObservationIgnored private let commands = RadarCommandCoordinator()
    @ObservationIgnored private var presentationObserverID: UUID?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var requestedQueryKey: ConsoleDerivedSnapshotKey?
    @ObservationIgnored private var lastFocusedFamilySignatures: Set<String> = []
    @ObservationIgnored private var nextRefreshCostSequence: UInt64 = 0

    init(monitor: ProcessMonitor, killer: ProcessKiller, openSettings: @escaping () -> Void = {}) {
        self.monitor = monitor
        self.killer = killer
        self.openSettings = openSettings
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
        state.focusedSelection.familyKey.flatMap { monitor.consoleSnapshot.detailPanel(for: $0) }
    }

    var selectedCompactDetail: CompactFamilyDetailModel? {
        selectedPanel.map(CompactFamilyDetailModel.init(panel:))
    }

    var familyItems: [FamilyTriageViewModel] {
        currentDerivedSnapshot().familyRows
    }

    var compactFamilyItems: [CompactSidebarRowModel] {
        currentDerivedSnapshot().compactFamilyRows
    }

    var incidentRows: [IncidentRowViewModel] {
        currentDerivedSnapshot().incidentRows
    }

    var duplicateRows: [DuplicateClusterViewModel] {
        currentDerivedSnapshot().duplicateRows
    }

    var commandCenter: OverviewCommandCenterModel {
        monitor.consoleSnapshot.compact.commandCenter
    }

    var compactSnapshot: CompactConsoleSnapshot {
        monitor.consoleSnapshot.compact
    }

    var compactSidebarSections: [CompactSidebarSection] {
        currentDerivedSnapshot().compactSidebarSections
    }

    var searchResults: ConsoleSearchResults {
        currentDerivedSnapshot().search
    }

    var snapshotContentToken: SnapshotContentRevision {
        monitor.consoleSnapshot.contentRevision
    }

    func availability(_ command: RadarCommand) -> RadarCommandAvailability {
        if command == .nextFamily || command == .previousFamily {
            return RadarCommandAvailability(
                command: command,
                isEnabled: !compactFamilyItems.isEmpty,
                reason: compactFamilyItems.isEmpty ? "No processes match the current filters." : nil
            )
        }
        return commands.availability(
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
            await RadarMotion.holdPerceptibly(since: started)
            isRefreshing = false
        }
    }

    func recordEngineSample() {
        var updatedThermals = thermalHistory
        if updatedThermals.append(monitor.thermals, at: Date()) { thermalHistory = updatedThermals }
        let milliseconds = monitor.performanceMetrics.lastRefresh.totalMilliseconds
        if milliseconds > 0 {
            nextRefreshCostSequence &+= 1
            refreshCostHistory.append(
                RefreshCostSample(
                    id: nextRefreshCostSequence,
                    milliseconds: milliseconds
                )
            )
        }
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
        queries.snapshot
    }

    func startPresentation() {
        guard presentationObserverID == nil else { return }
        presentationObserverID = monitor.addPublishedStateObserver { [weak self] _ in
            self?.receivePresentationUpdate()
        }
        receivePresentationUpdate()
    }

    func stopPresentation() {
        if let presentationObserverID { monitor.removePublishedStateObserver(presentationObserverID) }
        presentationObserverID = nil
        queryTask?.cancel()
        queryTask = nil
        requestedQueryKey = nil
        queries.cancel()
    }

    private func receivePresentationUpdate() {
        let title = monitor.consoleSnapshot.compact.commandCenter.statusText
        if navigationSubtitle != title { navigationSubtitle = title }
        recordEngineSample()
        scheduleQueryUpdate()
    }

    /// Returns the projection task for the current state, so callers that
    /// need fresh results (opening the best match) can wait for it.
    @discardableResult
    func scheduleQueryUpdate() -> Task<Void, Never>? {
        guard presentationObserverID != nil else { return nil }
        let request = ConsoleProjectionRequest(
            source: monitor.consoleSnapshot,
            incidents: monitor.incidents,
            state: state.coreState,
            families: monitor.families,
            processes: monitor.sampledProcesses,
            sampleRevision: monitor.sampleRevision
        )
        let key = ConsoleDerivedSnapshotKey(request)
        guard key != requestedQueryKey else { return queryTask }
        requestedQueryKey = key
        queryTask?.cancel()
        let queries = queries
        queryTask = Task { [weak self] in
            let published = await queries.update(request)
            guard published, !Task.isCancelled else { return }
            self?.updateFocusedFamilies()
        }
        return queryTask
    }

    func toggleInspector() {
        state.showInspector.toggle()
    }

    func nextFamily() {
        navigateFamily(direction: 1)
    }

    func previousFamily() {
        navigateFamily(direction: -1)
    }

    private func navigateFamily(direction: Int) {
        let current = selectedFamily.map { RadarFocusedSelection.family($0.familyKey) } ?? state.focusedSelection
        state.focusedSelection = commands.selection(
            after: current,
            orderedFamilyKeys: compactFamilyItems.map(\.familyKey),
            direction: direction
        )
        updateFocusedFamilies()
    }

    func focus(_ selection: RadarFocusedSelection) {
        hasNavigationIntent = true
        state.focusedSelection = selection
        updateFocusedFamilies()
    }

    func updateFocusedFamilies() {
        scheduleQueryUpdate()
        // The visible priority rows and selection identify concrete instances.
        // A logical signature here would promote every matching sibling too.
        var focusedKeys = Set(compactFamilyItems.prefix(8).map(\.familyKey))
        if let selected = selectedFamily {
            focusedKeys.insert(selected.familyKey)
        }
        guard focusedKeys != lastFocusedFamilySignatures else {
            return
        }
        lastFocusedFamilySignatures = focusedKeys
        monitor.focusFamilies(signatureIDs: focusedKeys)
    }

    func showToast(_ message: String, systemImage: String = "checkmark.circle") {
        toast = RadarToast(message: message, systemImage: systemImage)
    }

    func requestSearchFocus() {
        focus(.processes)
        searchFocusToken += 1
    }

    /// Return in the search field: open the best-matching family.
    func openBestMatch() {
        let pending = scheduleQueryUpdate()
        Task {
            await pending?.value
            guard !state.searchText.isEmpty, let best = familyItems.first else { return }
            focus(.family(best.familyKey))
        }
    }

    /// Appends a filter token such as `is:leaking` to the current search.
    func addSearchToken(_ token: String) {
        let current = state.searchText.trimmingCharacters(in: .whitespaces)
        guard !current.split(separator: " ").contains(Substring(token)) else { return }
        state.searchText = current.isEmpty ? token : "\(current) \(token)"
        focus(.processes)
    }

    func browseFamilies(filter: RadarFilter = .all, sort: RadarSort? = nil) {
        familyQueryResetToken += 1
        state.searchText = ""
        state.familyFilter = filter
        if let sort { state.familySort = sort }
        focus(.processes)
    }

    func clearFamilyFilters() {
        familyQueryResetToken += 1
        state.searchText = ""
        state.familyFilter = .all
        updateFocusedFamilies()
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

    private(set) var isPreparingIntervention = false

    func prepareKill(_ family: ProcessFamily, member: ProcessIdentity? = nil) {
        guard !isPreparingIntervention, pendingKill == nil else { return }
        isPreparingIntervention = true
        Task {
            defer { isPreparingIntervention = false }
            var plan = await monitor.killPlan(for: family)
            if let member {
                guard family.ownedIdentities.contains(member),
                      let process = family.members.first(where: { $0.identity == member }),
                      !process.isSystemProcess else {
                    showToast("This process cannot be targeted", systemImage: "lock")
                    return
                }
                plan = plan.targetingOnly(process)
            }
            let delay = monitor.settings.forceKillDelay
            let preview = await killer.preview(plan: plan, forceKillDelay: delay)
            let expiresAt = Date().addingTimeInterval(60)
            pendingKill = PendingKill(
                family: family,
                preview: preview,
                plan: plan.binding(to: preview.targetIdentities, expiresAt: expiresAt, strategy: preview.strategyRecommendation.strategy),
                forceKillDelay: delay,
                expiresAt: expiresAt
            )
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
            approvedPlan: pending.plan,
            forceKillDelay: pending.forceKillDelay,
            skipForce: skipForce,
            control: control,
            eventSink: eventSink
        )
    }
}

@MainActor
@Observable
final class RadarConsoleViewState {
    var focusedSelection: RadarFocusedSelection
    var searchText: String
    var familyFilter: RadarFilter
    var familySort: RadarSort
    var incidentQuery: IncidentQuery
    var showInspector: Bool

    init(_ state: RadarConsoleState = .default) {
        focusedSelection = state.focusedSelection
        searchText = state.searchText
        familyFilter = state.familyFilter
        familySort = state.familySort
        incidentQuery = state.incidentQuery
        showInspector = state.showInspector
    }

    var coreState: RadarConsoleState {
        RadarConsoleState(
            focusedSelection: focusedSelection,
            searchText: searchText,
            familyFilter: familyFilter,
            familySort: familySort,
            incidentQuery: incidentQuery,
            showInspector: showInspector
        )
    }
}

struct PendingKill: Identifiable {
    let id = UUID()
    let family: ProcessFamily
    let preview: KillPreview
    let plan: KillPlan
    let forceKillDelay: TimeInterval
    let expiresAt: Date
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

struct RefreshCostSample: Identifiable, Equatable {
    let id: UInt64
    let milliseconds: Double
}
