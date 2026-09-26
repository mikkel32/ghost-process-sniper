import AppKit
import GhostProcessSniperCore
import SwiftUI

/// A name with the characters that matched the search emphasized.
struct HighlightedText: View {
    let text: String
    let highlights: [Range<Int>]

    var body: some View {
        Text(highlights.isEmpty ? AttributedString(text) : Self.attributed(text, highlights))
    }

    static func attributed(_ text: String, _ highlights: [Range<Int>]) -> AttributedString {
        var result = AttributedString(text)
        let count = result.characters.count
        for range in highlights where range.lowerBound < count {
            // Re-read the view each time: indexes belong to one version.
            let characters = result.characters
            let lower = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let upper = characters.index(characters.startIndex, offsetBy: min(range.upperBound, count))
            result[lower..<upper].foregroundColor = RadarTheme.brand
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}

/// Echoes how the search was understood, so a filter never silently
/// narrows the list, and offers ready-made filters when the field is empty.
struct ProcessSearchSummary: View {
    let session: RadarConsoleSession

    private static let suggestions: [(label: String, token: String)] = [
        ("Needs attention", "is:attention"),
        ("Leaking", "is:leaking"),
        ("CPU above 20%", "cpu>20"),
        ("Memory above 1 GB", "mem>1gb"),
        ("Can stop", "is:killable"),
        ("Mine", "is:mine")
    ]

    var body: some View {
        let results = session.searchResults
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                Text(results.isActive ? "Showing matches for" : "Search names, commands, paths, PIDs or ports with \u{2318}F. Try:")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if results.isActive || session.state.familyFilter != .all {
                    Button("Clear") { session.clearFamilyFilters() }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            WrappingHStack(spacing: 6) {
                if results.isActive {
                    ForEach(results.query.tokens) { token in
                        SearchTokenChip(token: token)
                    }
                } else {
                    ForEach(Self.suggestions, id: \.token) { suggestion in
                        Button { session.addSearchToken(suggestion.token) } label: {
                            Text(suggestion.token)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RadarTheme.brand.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(suggestion.label)
                        .accessibilityLabel("Filter: \(suggestion.label)")
                    }
                }
            }

            if results.isApproximate {
                Label("No exact matches \u{2014} showing close spellings and initials.", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct SearchTokenChip: View {
    let token: ProcessSearchQuery.Token

    private var tint: Color {
        switch token.kind {
        case .text, .field: RadarTheme.brand
        case .metric: .orange
        case .flag: .purple
        case .identity: .teal
        case .ignored: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if token.isNegated {
                Image(systemName: "minus.circle.fill")
                    .accessibilityLabel("Excluding")
            }
            Text(token.label)
                .strikethrough(token.kind == .ignored)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(token.kind == .ignored ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Matching processes the radar does not track, so a search never comes up
/// empty just because an app is outside the current watch scope.
struct UntrackedProcessSection: View {
    let session: RadarConsoleSession
    let rows: [ProcessSearchRowModel]
    let hiddenCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 3) {
                Text("OTHER RUNNING PROCESSES")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                Text("Not tracked in \u{201c}\(session.monitor.settings.radarMode.userLabel)\u{201d} scope, so there is no trend or verdict. Widen the scope in Settings \u{203a} Protection to watch them.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 6)

            ForEach(rows) { row in
                UntrackedProcessRow(row: row)
                    .contextMenu { actions(for: row) }
            }
            if hiddenCount > 0 {
                Text("\(hiddenCount) more \u{2014} add words or filters to narrow the search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func actions(for row: ProcessSearchRowModel) -> some View {
        Button {
            copy("\(row.pid)", toast: "Copied PID \(row.pid)")
        } label: {
            Label("Copy PID", systemImage: "number")
        }
        if !row.commandLine.isEmpty {
            Button {
                copy(row.commandLine, toast: "Copied command line")
            } label: {
                Label("Copy Command Line", systemImage: "terminal")
            }
        }
        if !row.executablePath.isEmpty {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.executablePath)])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    private func copy(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        session.showToast(toast, systemImage: "doc.on.clipboard")
    }
}

private struct UntrackedProcessRow: View {
    let row: ProcessSearchRowModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: row.isSystemProcess ? "gearshape" : "app.dashed")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    HighlightedText(text: row.name, highlights: row.nameHighlights)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(row.detail.isEmpty ? row.ownerName : row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.memoryText).frame(width: 84, alignment: .trailing)
            Text(row.cpuText).frame(width: 64, alignment: .trailing)
            Text("PID \(row.pid)")
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            Color.clear.frame(width: 12, height: 1)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .help(row.commandLine.isEmpty ? row.executablePath : row.commandLine)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), PID \(row.pid), not tracked, memory \(row.memoryText), CPU \(row.cpuText)")
    }
}
