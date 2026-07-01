import GhostProcessSniperCore
import SwiftUI

struct RadarConsoleView: View {
    @Bindable var session: RadarConsoleSession

    @SceneStorage("GhostProcessSniper.Console.selection") private var storedSelection = "overview"
    @SceneStorage("GhostProcessSniper.Console.searchText") private var storedSearchText = ""
    @SceneStorage("GhostProcessSniper.Console.familyFilter") private var storedFamilyFilter = RadarFilter.all.rawValue
    @SceneStorage("GhostProcessSniper.Console.familySort") private var storedFamilySort = RadarSort.smart.rawValue
    @SceneStorage("GhostProcessSniper.Console.incidentText") private var storedIncidentText = ""
    @SceneStorage("GhostProcessSniper.Console.incidentFilter") private var storedIncidentFilter = RadarIncidentFilter.all.rawValue
    @SceneStorage("GhostProcessSniper.Console.incidentSort") private var storedIncidentSort = RadarIncidentSort.recent.rawValue
    @SceneStorage("GhostProcessSniper.Console.showInspector") private var storedShowInspector = false
    @State private var searchDraft = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var handledSearchFocusToken = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            RadarConsoleSidebar(session: session)
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        } detail: {
            RadarConsoleDetail(session: session)
                .inspector(isPresented: $session.state.showInspector) {
                    RadarConsoleInspector(session: session)
                        .inspectorColumnWidth(min: 260, ideal: 315, max: 380)
                }
        }
        .searchable(text: $searchDraft, placement: .toolbar, prompt: "Search process families")
        .searchFocused($searchFocused)
        .navigationSubtitle(session.commandCenter.statusText)
        .toolbar {
            RadarConsoleToolbar(session: session)
        }
        .overlay(alignment: .bottom) {
            if let toast = session.toast {
                RadarToastView(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.32), value: session.toast)
        .onChange(of: session.toast) { _, toast in
            toastDismissTask?.cancel()
            guard toast != nil else {
                return
            }
            toastDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                guard !Task.isCancelled else {
                    return
                }
                session.toast = nil
            }
        }
        .onChange(of: session.searchFocusToken) { _, token in
            handledSearchFocusToken = token
            searchFocused = true
        }
        .onAppear {
            restoreSceneState()
            searchDraft = session.state.searchText
            session.updateFocusedFamilies()
            session.refresh()
            // ⌘F can fire before this view attaches (window just created):
            // catch any focus request we missed.
            if session.searchFocusToken != handledSearchFocusToken {
                handledSearchFocusToken = session.searchFocusToken
                searchFocused = true
            }
        }
        .onChange(of: session.state.focusedSelection) { _, selection in
            storedSelection = selection.storageValue
            session.updateFocusedFamilies()
        }
        .onChange(of: searchDraft) { _, value in
            storedSearchText = value
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled else {
                    return
                }
                session.state.searchText = value
                session.updateFocusedFamilies()
            }
        }
        .onChange(of: session.snapshotContentToken) { _, _ in
            session.updateFocusedFamilies()
            session.recordEngineSample()
        }
        .onChange(of: session.state.familyFilter) { _, value in
            storedFamilyFilter = value.rawValue
            session.updateFocusedFamilies()
        }
        .onChange(of: session.state.familySort) { _, value in
            storedFamilySort = value.rawValue
            session.updateFocusedFamilies()
        }
        .onChange(of: session.state.incidentQuery.filter) { _, value in
            storedIncidentFilter = value.rawValue
        }
        .onChange(of: session.state.incidentQuery.text) { _, value in
            storedIncidentText = value
        }
        .onChange(of: session.state.incidentQuery.sort) { _, value in
            storedIncidentSort = value.rawValue
        }
        .onChange(of: session.state.showInspector) { _, value in
            storedShowInspector = value
        }
        .sheet(item: $session.pendingKill) { pending in
            KillPreviewSheet(
                family: pending.family,
                preview: pending.preview,
                confirm: { skipForce, control, eventSink in
                    await session.confirmKill(
                        pending,
                        skipForce: skipForce,
                        control: control,
                        eventSink: eventSink
                    )
                },
                close: {
                    session.pendingKill = nil
                }
            )
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            toastDismissTask?.cancel()
        }
    }

    private func restoreSceneState() {
        session.state.focusedSelection = RadarFocusedSelection(storageValue: storedSelection)
        session.state.searchText = storedSearchText
        session.state.familyFilter = RadarFilter(rawValue: storedFamilyFilter) ?? .all
        session.state.familySort = RadarSort(rawValue: storedFamilySort) ?? .smart
        session.state.incidentQuery.text = storedIncidentText
        session.state.incidentQuery.filter = RadarIncidentFilter(rawValue: storedIncidentFilter) ?? .all
        session.state.incidentQuery.sort = RadarIncidentSort(rawValue: storedIncidentSort) ?? .recent
        session.state.showInspector = storedShowInspector
    }
}

private extension RadarFocusedSelection {
    var storageValue: String {
        switch self {
        case .overview:
            "overview"
        case .duplicates:
            "duplicates"
        case .incidents:
            "incidents"
        case .rules:
            "rules"
        case .engine:
            "engine"
        case .family(let signatureID):
            "family|\(signatureID)"
        }
    }

    init(storageValue: String) {
        if storageValue.hasPrefix("family|") {
            self = .family(String(storageValue.dropFirst("family|".count)))
            return
        }
        switch storageValue {
        case "overview":
            self = .overview
        case "duplicates":
            self = .duplicates
        case "incidents":
            self = .incidents
        case "rules":
            self = .rules
        default:
            self = .engine
        }
    }
}
