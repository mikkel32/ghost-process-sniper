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
