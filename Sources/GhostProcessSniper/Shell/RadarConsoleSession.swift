import Accessibility
import AppKit
import GhostProcessSniperCore
import Observation

@MainActor
@Observable
final class RadarConsoleSession {
    let monitor: ProcessMonitor
    let killer: ProcessKiller
    let quickStops: QuickStopAdvisor
    let openSettings: () -> Void
    let queries = ConsoleQueryStore()
    private(set) var navigationSubtitle = "Monitoring"

    var state = RadarConsoleViewState()
    var pendingKill: PendingKill?
    var toast: RadarToast?
    var searchFocusToken = 0
    var familyQueryResetToken = 0
    var showQuickGuide = false
    /// The first-run welcome sheet, set once by the launch that decided on it.
    var showWelcome = false
    private(set) var isRefreshing = false
    /// Drives the Stop toolbar button and menu item without making them
    /// depend on `monitor.families`, which changes every sample.
    private(set) var canStopSelection = false
    /// The last stop per family key, so a page whose family is gone can say
    /// what happened instead of "no longer running".
    private(set) var recentStops: [String: KillReport] = [:]
    private(set) var memoryPulse: [MemoryPulseSample] = []
    /// Where each family sat on the Live Radar over the last five minutes.
    private(set) var radarHistory = LiveRadarHistory()
    /// Set from the moment a stop is requested until its preview is ready.
    var preparingStop: PreparingStop?
    /// The open "Stop the extras" run. It lives here, not on the Duplicates
    /// page, so its sheet survives moving to another page mid-run.
    var cullRun: DuplicateCullRun?
    /// The Incidents page has asked for the whole log and its rows are not the
    /// log's yet. See `incidentHistoryForProjection`.
    var isSearchingIncidentLog = false
    /// Changes only when the thermal panel should move on the Overview.
    var overviewThermalBand: OverviewThermalBand = .normal
    /// Changes only when the two queues collapse into the all-clear strip or
    /// come back out of it.
    var overviewQueueLayout: OverviewQueueLayout = .allClear
    var history = NavigationHistory()
    @ObservationIgnored var thermalBandTracker = OverviewThermalBandTracker()
    /// The incident log read past the published 80 while the Incidents page is
    /// searched or filtered; nothing while it is not.
    @ObservationIgnored var incidentHistoryTracker = IncidentHistoryTracker()
    @ObservationIgnored var queueLayoutTracker = OverviewQueueTracker()
    /// The last confirmed stop, so closing its sheet can return the user.
    @ObservationIgnored var lastStopResult: (pendingID: UUID, report: KillReport)?

    @ObservationIgnored private let commands = RadarCommandCoordinator()
    @ObservationIgnored private var presentationObserverID: UUID?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var panelTask: Task<Void, Never>?
    @ObservationIgnored private var requestedQueryKey: ConsoleDerivedSnapshotKey?
    @ObservationIgnored private var lastFocusedFamilySignatures: Set<String> = []
    @ObservationIgnored private(set) var isVisible = false
    @ObservationIgnored private var familyIndex: [String: Int] = [:]
    @ObservationIgnored private var familyIndexRevision: UInt64 = .max
    @ObservationIgnored private var recentStopOrder: [String] = []
    /// The ports the last `port:` census was requested for, and when.
    @ObservationIgnored var censusPorts: Set<Int> = []
    @ObservationIgnored var lastPortCensusAt: Date?

    init(
        monitor: ProcessMonitor,
        killer: ProcessKiller,
        quickStops: QuickStopAdvisor,
        openSettings: @escaping () -> Void = {}
    ) {
        self.monitor = monitor
        self.killer = killer
        self.quickStops = quickStops
        self.openSettings = openSettings
        state.familySortInNaturalDirection = ConsolePreferences.familySort
        state.familyFilter = ConsolePreferences.familyFilter
        history.visit(state.focusedSelection)
    }

    var selectedFamily: ProcessFamily? {
        state.focusedSelection.familyKey.flatMap { family(forKey: $0) }
    }

    /// Looks a family up by family key or signature ID without scanning every
    /// family and rebuilding its key string. Reading `monitor.families` keeps
    /// live pages following each sample; the index is rebuilt once per sample.
    func family(forKey key: String) -> ProcessFamily? {
        let families = monitor.families
        if monitor.sampleRevision != familyIndexRevision {
            var index: [String: Int] = [:]
            index.reserveCapacity(families.count * 2)
            for (offset, family) in families.enumerated() {
                if index[family.familyKey] == nil { index[family.familyKey] = offset }
                if index[family.signature.id] == nil { index[family.signature.id] = offset }
            }
            familyIndex = index
            familyIndexRevision = monitor.sampleRevision
        }
        if let offset = familyIndex[key], families.indices.contains(offset),
           families[offset].familyKey == key || families[offset].signature.id == key {
            return families[offset]
        }
        return families.first { $0.familyKey == key || $0.signature.id == key }
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

    /// Which incidents `incidentRows` were drawn from.
    var incidentScope: IncidentListScope {
        currentDerivedSnapshot().incidentScope
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
        // Pulse points every few seconds are plenty for a 5-minute strip and
        // keep the chart from rebuilding on every refresh tick.
        let now = Date()
        var history = radarHistory
        if history.record(compactSnapshot.allRows.map(LiveRadarInput.init(row:)), at: now) { radarHistory = history }
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

    /// Presentation runs only while the window is on screen: a minimized or
    /// covered console stops projecting queries, recording histories and
    /// asking the engine to prioritise its families.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            startPresentation()
            updateFocusedFamilies()
        } else {
            stopPresentation()
        }
    }

    func startPresentation() {
        guard presentationObserverID == nil else { return }
        presentationObserverID = monitor.addPublishedStateObserver { [weak self] _ in
            self?.receivePresentationUpdate()
        }
        // Draw real rows on the first frame; the async projection refines them.
        if queries.snapshot.key.contentRevision != monitor.consoleSnapshot.contentRevision {
            queries.seed(ConsoleDerivedSnapshot.build(
                snapshot: monitor.consoleSnapshot,
                incidents: monitor.incidents,
                state: state.coreState
            ))
        }
        receivePresentationUpdate()
    }

    func stopPresentation() {
        if let presentationObserverID { monitor.removePublishedStateObserver(presentationObserverID) }
        presentationObserverID = nil
        queryTask?.cancel()
        queryTask = nil
        panelTask?.cancel()
        panelTask = nil
        requestedQueryKey = nil
        queries.cancel()
        incidentHistoryTracker.reset()
        isSearchingIncidentLog = false
        // Otherwise every later refresh keeps prioritising forensics for
        // families nobody is looking at.
        lastFocusedFamilySignatures = []
        monitor.focusFamilies(signatureIDs: [])
    }

    private func receivePresentationUpdate() {
        let title = monitor.consoleSnapshot.compact.commandCenter.statusText
        if navigationSubtitle != title { navigationSubtitle = title }
        recordEngineSample()
        updateOverviewThermalBand()
        updateOverviewQueueLayout()
        renewPortCensusIfUnanswered()
        scheduleQueryUpdate()
        updateCanStopSelection()
        schedulePanelUpdate()
    }

    func updateCanStopSelection() {
        canStopSelection = selectedFamily.map { !$0.ownedIdentities.isEmpty } ?? false
    }

    /// A selected family the refresh did not prepare gets its panel from the
    /// worker now, and again with every sample while it stays unprepared.
    func schedulePanelUpdate() {
        guard presentationObserverID != nil, let family = selectedFamily,
              monitor.consoleSnapshot.detailPanel(for: family.familyKey) == nil else { return }
        let request = ConsoleProjectionRequest(
            source: monitor.consoleSnapshot,
            incidents: [],
            state: state.coreState,
            families: monitor.families,
            processes: monitor.sampledProcesses,
            sampleRevision: monitor.sampleRevision
        )
        panelTask?.cancel()
        let queries = queries
        let familyKey = family.familyKey
        panelTask = Task {
            _ = await queries.updatePanel(familyKey: familyKey, request: request)
        }
    }

    /// Returns the projection task for the current state, so callers that
    /// need fresh results (opening the best match) can wait for it.
    @discardableResult
    func scheduleQueryUpdate() -> Task<Void, Never>? {
        guard presentationObserverID != nil else { return nil }
        let request = ConsoleProjectionRequest(
            source: monitor.consoleSnapshot,
            incidents: monitor.incidents,
            incidentHistory: incidentHistoryForProjection(),
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
            self?.syncIncidentSearchState()
            self?.updateFocusedFamilies()
        }
        return queryTask
    }

    func toggleInspector() {
        // Off a family page there is no inspector to show, and flipping the
        // saved choice there would change what the next family page opens with.
        guard state.focusedSelection.familyKey != nil else { return }
        state.showInspector.toggle()
        // Remembered for the next family page, including after relaunch.
        ConsolePreferences.showInspector = state.showInspector
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
        recordVisit(state.focusedSelection)
        updateFocusedFamilies()
        updateCanStopSelection()
        schedulePanelUpdate()
    }

    func focus(_ selection: RadarFocusedSelection) {
        state.focusedSelection = canonicalSelection(selection)
        recordVisit(state.focusedSelection)
        updateFocusedFamilies()
        updateCanStopSelection()
        schedulePanelUpdate()
    }

    /// Family selections carry the concrete family key: prebuilt panels and
    /// the sidebar highlight are keyed by it, not by a signature id.
    func canonicalSelection(_ selection: RadarFocusedSelection) -> RadarFocusedSelection {
        commands.canonicalSelection(selection, families: monitor.families)
    }

    func updateFocusedFamilies() {
        // A hidden console must not steer the engine; showing it again re-runs this.
        guard isVisible else { return }
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

    func showToast(_ message: String, systemImage: String = "checkmark.circle", action: RadarToast.Action? = nil) {
        toast = RadarToast(message: message, systemImage: systemImage, action: action)
        AccessibilityNotification.Announcement(message).post()
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
        if let sort {
            state.familySortInNaturalDirection = sort
        }
        focus(.processes)
    }

    func clearFamilyFilters() {
        familyQueryResetToken += 1
        state.searchText = ""
        state.familyFilter = .all
        updateFocusedFamilies()
    }

    func snoozeSelected(minutes: TimeInterval = 60) {
        guard let signatureID = selectedFamily?.signature.id ?? state.focusedSelection.familyKey else {
            return
        }
        snooze(familyKey: signatureID, name: selectedFamily?.displayName, minutes: minutes)
    }

    func ignoreSelected() {
        guard let signatureID = selectedFamily?.signature.id ?? state.focusedSelection.familyKey else {
            return
        }
        ignore(familyKey: signatureID, name: selectedFamily?.displayName)
    }

    // The toast follows the save, so it never announces a rule that is not there.
    func snooze(familyKey: String, name: String? = nil, minutes: TimeInterval = 60) {
        Task {
            await monitor.snooze(signatureID: familyKey, name: name, minutes: minutes)
            showToast("Snoozed \(name ?? "family") for \(Self.durationText(minutes: minutes))", systemImage: "moon")
        }
    }

    func ignore(familyKey: String, name: String? = nil) {
        Task {
            await monitor.ignore(signatureID: familyKey, name: name)
            showToast("Ignoring \(name ?? "family") — undo under Rules", systemImage: "eye.slash")
        }
    }

    func prepareKillSelected() {
        guard let family = selectedFamily, !refusesStopDuringCull() else {
            return
        }
        prepareKill(family)
    }

    /// - Parameter name: shown when the family exited before the stop began.
    func prepareKill(familyKey: String, name: String? = nil, redirectedFrom: String? = nil) {
        guard !refusesStopDuringCull() else { return }
        guard let family = self.family(forKey: familyKey) else {
            showToast("\(name ?? "That process") is no longer running", systemImage: "info.circle")
            return
        }
        prepareKill(family, redirectedFrom: redirectedFrom)
    }

    static func durationText(minutes: TimeInterval) -> String {
        if minutes < 60 {
            return "\(Int(minutes)) min"
        }
        let hours = minutes / 60
        return hours == hours.rounded() ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
    }

    /// A stop preview is being computed; stop buttons show it and ignore repeat clicks.
    var isPreparingIntervention: Bool { preparingStop != nil }
    /// The open stop preview is being computed again.
    var isRefreshingPreview = false

    /// Stops from outside the window (a notification, Quick Stop, the menu)
    /// wait while the cull sheet is open: it holds the window, so a stop
    /// preview could not be shown.
    func refusesStopDuringCull() -> Bool {
        guard cullRun != nil else { return false }
        showToast("Finish stopping the duplicate copies first", systemImage: "hourglass")
        return true
    }

    /// Keeps the last stop per family for RecentStopView, at most 20.
    func rememberStop(_ report: KillReport, familyKey: String) {
        recentStopOrder.removeAll { $0 == familyKey }
        recentStopOrder.append(familyKey)
        recentStops[familyKey] = report
        while recentStopOrder.count > 20 {
            recentStops[recentStopOrder.removeFirst()] = nil
        }
    }
}

@MainActor
@Observable
final class RadarConsoleViewState {
    var focusedSelection: RadarFocusedSelection
    var searchText: String
    var familyFilter: RadarFilter
    var familySort: RadarSort
    var familySortAscending: Bool
    var incidentQuery: IncidentQuery
    var showInspector: Bool

    /// Menus, links and restored scenes pick a sort in its usual
    /// direction; only the table headers choose the other one.
    var familySortInNaturalDirection: RadarSort {
        get { familySort }
        set {
            familySort = newValue
            familySortAscending = newValue.isNaturallyAscending
        }
    }

    init(_ state: RadarConsoleState = .default) {
        focusedSelection = state.focusedSelection
        searchText = state.searchText
        familyFilter = state.familyFilter
        familySort = state.familySort
        familySortAscending = state.familySortAscending
        incidentQuery = state.incidentQuery
        showInspector = state.showInspector
    }

    var coreState: RadarConsoleState {
        RadarConsoleState(
            focusedSelection: focusedSelection,
            searchText: searchText,
            familyFilter: familyFilter,
            familySort: familySort,
            familySortAscending: familySortAscending,
            incidentQuery: incidentQuery,
            showInspector: showInspector
        )
    }
}

struct PreparingStop: Equatable {
    let id = UUID()
    let name: String
}

struct RadarToast: Identifiable, Equatable {
    /// One button on the toast, such as Undo.
    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    let id = UUID()
    let message: String
    let systemImage: String
    var action: Action? = nil

    static func == (lhs: RadarToast, rhs: RadarToast) -> Bool {
        lhs.id == rhs.id
    }
}

struct MemoryPulseSample: Identifiable, Equatable {
    let date: Date
    let trackedBytes: UInt64

    var id: Date {
        date
    }
}
