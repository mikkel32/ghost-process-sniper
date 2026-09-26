import GhostProcessSniperCore
import SwiftUI

struct RadarConsoleView: View {
    @Bindable var session: RadarConsoleSession

    @State private var searchDraft: String
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var handledSearchFocusToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    init(session: RadarConsoleSession) {
        self.session = session
        // The session outlives the window, so a reopened console resumes its query.
        _searchDraft = State(initialValue: session.state.searchText)
    }

    private var decoratedConsole: some View {
        // Keep a single structural identity for the split view. Toggling the
        // searchable modifier used to recreate the sidebar and its motion state.
        consoleShell
        .searchable(text: $searchDraft, placement: .toolbar, prompt: "Search processes, PIDs, ports")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            commitSearchDraft()
            session.openBestMatch()
        }
        .tint(RadarTheme.brand)
        .navigationSubtitle(session.navigationSubtitle)
        .toolbar {
            RadarConsoleToolbar(session: session)
        }
        .overlay(alignment: .bottom) {
            // Animate only the toast; list and selection changes in the same
            // transaction must not pick up the spring.
            ZStack {
                if let toast = session.toast {
                    RadarToastView(toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.32), value: session.toast)
        }
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
    }

    private var searchedConsole: some View {
        decoratedConsole
        .onChange(of: session.searchFocusToken) { _, token in
            handledSearchFocusToken = token
            if showsGlobalSearch {
                searchFocused = true
            }
        }
        .onAppear {
            // Showing the window already starts a fresh sample (setConsoleVisible).
            session.setVisible(true)
            // ⌘F can fire before this view attaches (window just created):
            // catch any focus request we missed.
            if showsGlobalSearch, session.searchFocusToken != handledSearchFocusToken {
                handledSearchFocusToken = session.searchFocusToken
                searchFocused = true
            }
        }
        .onChange(of: session.state.focusedSelection) { _, selection in
            Task { @MainActor in
                await Task.yield()
                guard session.state.focusedSelection == selection else {
                    return
                }
                // The inspector belongs to family pages; it reopens with the
                // user's last explicit choice.
                session.state.showInspector = selection.familyKey != nil && ConsolePreferences.showInspector
                session.updateFocusedFamilies()
            }
        }
        .onChange(of: searchDraft) { _, value in
            // Results live on the process list (Duplicates filters in place).
            // Only a user edit navigates; syncing from state never does.
            if value != session.state.searchText, !value.trimmingCharacters(in: .whitespaces).isEmpty,
               session.state.focusedSelection != .processes, session.state.focusedSelection != .duplicates {
                session.focus(.processes)
            }
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
        .onChange(of: session.state.searchText) { _, value in
            guard value != searchDraft else { return }
            searchDebounceTask?.cancel()
            searchDraft = value
        }
        .onChange(of: session.familyQueryResetToken) { _, _ in
            // Invalidate a pending keystroke even when the committed query is already empty.
            searchDebounceTask?.cancel()
            searchDraft = ""
        }
        .task(id: showsGlobalSearch) {
            if showsGlobalSearch, session.searchFocusToken > 0 {
                searchFocused = true
            }
        }
    }

    private var persistedConsole: some View {
        searchedConsole
        .onChange(of: session.state.familyFilter) { _, value in
            ConsolePreferences.familyFilter = value
            session.updateFocusedFamilies()
        }
        .onChange(of: session.state.familySort) { _, value in
            ConsolePreferences.familySort = value
            session.updateFocusedFamilies()
        }
        .onChange(of: session.state.incidentQuery.filter) { _, _ in
            session.scheduleQueryUpdate()
        }
        .onChange(of: session.state.incidentQuery.text) { _, _ in
            session.scheduleQueryUpdate()
        }
        .onChange(of: session.state.incidentQuery.sort) { _, _ in
            session.scheduleQueryUpdate()
        }
    }

    var body: some View {
        persistedConsole
        .sheet(item: $session.pendingKill) { pending in
            KillPreviewSheet(
                family: pending.family,
                preview: pending.preview,
                approvalExpiresAt: pending.expiresAt,
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
        .sheet(isPresented: $session.showQuickGuide) {
            RadarQuickGuideView()
        }
        .onDisappear {
            session.setVisible(false)
            searchDebounceTask?.cancel()
            toastDismissTask?.cancel()
        }
    }

    private var consoleShell: some View {
        NavigationSplitView {
            RadarConsoleSidebar(session: session)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            RadarConsoleDetail(session: session)
                .inspector(isPresented: $session.state.showInspector) {
                    RadarConsoleInspector(session: session)
                        .inspectorColumnWidth(min: 260, ideal: 315, max: 380)
                }
        }
    }

    private func commitSearchDraft() {
        searchDebounceTask?.cancel()
        guard session.state.searchText != searchDraft else { return }
        session.state.searchText = searchDraft
        session.updateFocusedFamilies()
    }

    private var showsGlobalSearch: Bool {
        switch session.state.focusedSelection {
        case .overview, .processes, .family, .duplicates:
            true
        case .incidents, .rules, .engine:
            false
        }
    }
}
