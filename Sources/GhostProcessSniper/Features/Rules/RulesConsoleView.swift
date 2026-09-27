import GhostProcessSniperCore
import SwiftUI

struct RulesConsoleView: View {
    let session: RadarConsoleSession
    @State private var showsComposer = false
    @State private var showsBuiltIns = false

    var body: some View {
        let snapshot = session.monitor.consoleSnapshot
        // One lookup table per body instead of a scan per row.
        let rowsByID = Dictionary(snapshot.ruleRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previewsByID = Dictionary(snapshot.rulePreviews.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = session.monitor.rules.map { rule in
            RuleEntry(rule: rule, row: rowsByID[rule.id] ?? RuleRowViewModel(rule: rule), preview: previewsByID[rule.id])
        }
        let builtIns = entries.filter { $0.row.kind == .builtIn }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(matchCount: snapshot.rulePreviews.reduce(0) { $0 + $1.matchCount })
                ruleGroup("Snoozed", systemImage: "moon", entries: entries.filter { $0.row.kind == .snooze },
                          empty: "Nothing snoozed. Snooze a family from its page or any row menu.")
                ruleGroup("Ignored", systemImage: "eye.slash", entries: entries.filter { $0.row.kind == .ignore },
                          empty: "Nothing ignored.")
                ruleGroup("Your Rules", systemImage: "slider.horizontal.3", entries: entries.filter { $0.row.kind == .custom },
                          empty: "No rules yet. Add one to highlight, notify or snooze matching processes.")
                DisclosureGroup(isExpanded: $showsBuiltIns) {
                    LazyVStack(spacing: 8) {
                        ForEach(builtIns) { entry in
                            RuleConsoleRow(entry: entry, session: session)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Built-in (\(builtIns.count))", systemImage: "lock.shield")
                        .font(.headline)
                }
                .padding(14)
                .radarSurface(tint: .purple)
            }
            .padding(24)
        }
        .sheet(isPresented: $showsComposer) {
            RuleComposerSheet(session: session, isPresented: $showsComposer)
        }
    }

    private func header(matchCount: Int) -> some View {
        RadarPageHeader(
            eyebrow: "Policy Studio",
            title: "Rules",
            subtitle: "Your snoozes and ignores first, then your own rules",
            systemImage: "slider.horizontal.3",
            accent: .purple
        ) {
            InfoTip(tip: RadarTip(
                title: "Rules",
                message: "Advisory automations that match families by command, path, level, or leak rate. Your snoozes and ignores are listed first: Unsnooze or Stop Ignoring undoes one. Nothing destructive ever runs without an explicit confirmation.",
                shortcut: "⌘6"
            ))
            RadarChip(title: "Matches", value: "\(matchCount)", systemImage: "scope")
                .frame(width: 150)
            Button("Add Rule", systemImage: "plus") {
                showsComposer = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func ruleGroup(_ title: String, systemImage: String, entries: [RuleEntry], empty: String) -> some View {
        RadarSection(title: title, subtitle: "\(entries.count)", systemImage: systemImage, accent: .purple) {
            if entries.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(entries) { entry in
                        RuleConsoleRow(entry: entry, session: session)
                    }
                }
            }
        }
    }
}

private struct RuleEntry: Identifiable {
    let rule: RadarRule
    let row: RuleRowViewModel
    let preview: RuleMatchPreview?

    var id: UUID { rule.id }
}

private struct RuleConsoleRow: View {
    let entry: RuleEntry
    let session: RadarConsoleSession

    private var row: RuleRowViewModel { entry.row }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(row.isEnabled ? .primary : .tertiary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(row.actionText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                if row.kind == .snooze, let expiresAt = row.expiresAt {
                    Text("Ends in \(expiresAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(row.matchText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let preview = entry.preview, preview.matchCount > 0 {
                    FlowTags(title: "\(preview.matchCount) matches", items: preview.matchedFamilyNames)
                }
            }
            Spacer()
            controls
        }
        .padding(12)
        .radarSurface(tint: .purple, cornerRadius: 14)
    }

    @ViewBuilder
    private var controls: some View {
        switch row.kind {
        case .snooze:
            Button("Unsnooze", systemImage: "bell") {
                session.removeRule(entry.rule, message: "Unsnoozed \(subject)")
            }
        case .ignore:
            Button("Stop Ignoring", systemImage: "eye") {
                session.removeRule(entry.rule, message: "Watching \(subject) again")
            }
        case .custom:
            Toggle(isOn: Binding(
                get: { row.isEnabled },
                set: { enabled in
                    let id = entry.rule.id
                    Task { await session.monitor.setRuleEnabled(id: id, isEnabled: enabled) }
                }
            )) {
                Text("Enable \(row.name)")
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable \(row.name)")
            Button("Delete", systemImage: "trash", role: .destructive) {
                session.removeRule(entry.rule, message: "Deleted \(row.name)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Delete rule")
        case .builtIn:
            EmptyView()
        }
    }

    /// "Snooze node" reads as "node" in a toast.
    private var subject: String {
        for prefix in ["Snooze ", "Ignore "] where row.name.hasPrefix(prefix) {
            return String(row.name.dropFirst(prefix.count))
        }
        return row.name
    }

    private var icon: String {
        switch entry.rule.action {
        case .notify: "bell"
        case .highlight: "highlighter"
        case .snooze: "moon"
        case .ignore: "eye.slash"
        case .inspect: "info.circle"
        case .suggestKill: "scope"
        case .kill: "scope"
        }
    }
}

/// The new-rule form. Its live match preview waits for typing to pause.
private struct RuleComposerSheet: View {
    let session: RadarConsoleSession
    @Binding var isPresented: Bool

    @State private var draft: RuleDraft = .empty
    @State private var preview: RuleMatchPreview?

    var body: some View {
        let candidate = draft.makeRule(existingRules: [])
        let isDuplicate = candidate != nil && draft.makeRule(existingRules: session.monitor.rules) == nil
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Detection Rule")
                        .font(.title2.weight(.bold))
                    Text("Preview live matches before saving the policy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            RadarSection(
                title: "New Rule",
                subtitle: isDuplicate ? "duplicate" : "preview before save",
                systemImage: "plus.circle",
                accent: .purple
            ) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Command")
                        TextField("Command contains", text: $draft.commandContains)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Path")
                        TextField("Path contains", text: $draft.pathContains)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Level")
                        Picker("Minimum level", selection: $draft.minimumLevel) {
                            ForEach(GhostLevel.allCases, id: \.self) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    GridRow {
                        Text("Action")
                        HStack {
                            Picker("Action", selection: $draft.action) {
                                ForEach([RadarActionType.notify, .highlight, .inspect, .suggestKill, .snooze, .ignore], id: \.self) { action in
                                    Text(action.label).tag(action)
                                }
                            }
                            .frame(width: 170)

                            Spacer()

                            Button("Add", systemImage: "plus") {
                                let submitted = draft
                                Task {
                                    await session.monitor.addRule(draft: submitted)
                                    isPresented = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(candidate == nil || isDuplicate)
                        }
                    }
                }

                if candidate != nil, let preview {
                    FlowTags(
                        title: "\(preview.matchCount) live matches",
                        items: preview.matchedFamilyNames.isEmpty ? ["none"] : preview.matchedFamilyNames
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            preview = draft.makeRule(existingRules: []).map { RuleMatchPreview(rule: $0, families: session.monitor.families) }
        }
    }
}
