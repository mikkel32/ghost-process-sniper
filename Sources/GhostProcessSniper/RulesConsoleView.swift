import GhostProcessSniperCore
import SwiftUI

struct RulesConsoleView: View {
    @Bindable var session: RadarConsoleSession
    @State private var draft: RuleDraft = .empty

    private var builtIns: [RadarRule] {
        session.monitor.rules.filter(\.isBuiltIn)
    }

    private var customRules: [RadarRule] {
        session.monitor.rules.filter { !$0.isBuiltIn }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ruleComposer
                ruleGroup("Built-in Rules", rules: builtIns)
                ruleGroup("Custom Rules", rules: customRules)
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Rules")
                        .font(.largeTitle.weight(.semibold))
                    InfoTip(tip: RadarTip(
                        title: "Rules",
                        message: "Advisory automations that match families by command, path, level, or leak rate. Your snoozes and ignores live here too — delete a rule to undo one. Nothing destructive ever runs without an explicit confirmation.",
                        shortcut: "⌘4"
                    ))
                }
                Text("Advisory automations. Nothing destructive runs without confirmation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RadarChip(title: "Matches", value: "\(session.monitor.consoleSnapshot.rulePreviews.reduce(0) { $0 + $1.matchCount })", systemImage: "scope")
                .frame(width: 150)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var ruleComposer: some View {
        RadarSection(title: "New Rule", subtitle: draft.makeRule(existingRules: session.monitor.rules) == nil && draft.isValid ? "duplicate" : "preview before save") {
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

                        Button {
                            Task {
                                await session.monitor.addRule(draft: draft)
                                draft = .empty
                            }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.isValid || draft.makeRule(existingRules: session.monitor.rules) == nil)
                    }
                }
            }

            if let candidate = draft.makeRule(existingRules: []) {
                let preview = RuleMatchPreview(rule: candidate, families: session.monitor.families)
                FlowTags(
                    title: "\(preview.matchCount) live matches",
                    items: preview.matchedFamilyNames.isEmpty ? ["none"] : preview.matchedFamilyNames
                )
            }
        }
    }

    private func ruleGroup(_ title: String, rules: [RadarRule]) -> some View {
        RadarSection(title: title, subtitle: "\(rules.count)") {
            if rules.isEmpty {
                ContentUnavailableView("No Rules", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(rules) { rule in
                        RuleConsoleRow(
                            rule: rule,
                            row: session.monitor.consoleSnapshot.ruleRows.first { $0.id == rule.id } ?? RuleRowViewModel(rule: rule),
                            preview: session.monitor.consoleSnapshot.rulePreviews.first { $0.id == rule.id },
                            setEnabled: { enabled in
                                Task { await session.monitor.setRuleEnabled(id: rule.id, isEnabled: enabled) }
                            },
                            delete: {
                                Task { await session.monitor.deleteRule(id: rule.id) }
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct RuleConsoleRow: View {
    let rule: RadarRule
    let row: RuleRowViewModel
    let preview: RuleMatchPreview?
    let setEnabled: @MainActor (Bool) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(row.isEnabled ? .primary : .tertiary)
                .frame(width: 24)
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
                Text(row.matchText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let preview, preview.matchCount > 0 {
                    FlowTags(title: "\(preview.matchCount) matches", items: preview.matchedFamilyNames)
                }
            }
            Spacer()
            if !rule.isBuiltIn {
                Button {
                    setEnabled(!row.isEnabled)
                } label: {
                    Image(systemName: row.isEnabled ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.borderless)
                .help(row.isEnabled ? "Disable rule" : "Enable rule")

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .glassEffect(.regular.interactive(true), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var icon: String {
        switch rule.action {
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
