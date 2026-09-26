import GhostProcessSniperCore
import SwiftUI

// Evidence and Details sections of the family page. Each takes only the
// slice of the panel it shows, so a refresh that changes something else
// does not re-render it.

struct FamilyScorePanel: View, Equatable {
    let components: [GhostScoreComponent]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components
    }

    var body: some View {
        RadarSection(
            title: "Why Flagged",
            subtitle: "\(components.count) signals",
            systemImage: "list.bullet.rectangle",
            tip: RadarTip(
                title: "Why Flagged",
                message: "These diagnostic cards explain the internal evidence score. Action levels also consider persistence, trend quality, learned normal behavior, and system pressure. Neither is a temperature; measured Celsius is shown in Hardware temperatures."
            ),
            accent: .red
        ) {
            if components.isEmpty {
                Text("No elevated score components.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                    ForEach(components.prefix(10)) { component in
                        ScoreComponentView(component: component)
                    }
                }
            }
        }
    }
}

struct FamilyCulpritPanel: View, Equatable {
    let culprit: CulpritAnalysis
    let level: GhostLevel

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.culprit == rhs.culprit && lhs.level == rhs.level
    }

    var body: some View {
        RadarSection(
            title: "Culprit",
            subtitle: culprit.kind.label,
            systemImage: "target",
            tip: RadarTip(
                title: "Culprit",
                message: "The engine's best guess at what spawned this family and why it's still here — inferred from command lines, working directories, and process ancestry. The evidence tags show what the guess is based on."
            ),
            accent: .purple
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "target")
                        .foregroundStyle(RadarStyle.color(for: level))
                        .accessibilityHidden(true)
                    Text(culprit.likelyCause)
                }
                .font(.headline)

                if let repoHint = culprit.repoHint {
                    Label(repoHint, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                FlowTags(title: "Evidence", items: culprit.evidence)
            }
        }
    }
}

struct FamilyForecastPanel: View, Equatable {
    let stateText: String
    let confidenceText: String
    let whyNow: String
    let cards: [FamilyMetricCard]
    let level: GhostLevel

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stateText == rhs.stateText && lhs.confidenceText == rhs.confidenceText &&
            lhs.whyNow == rhs.whyNow && lhs.cards == rhs.cards && lhs.level == rhs.level
    }

    var body: some View {
        RadarSection(
            title: "Forecast",
            subtitle: "\(stateText) · \(confidenceText) confidence",
            systemImage: "clock.badge.exclamationmark",
            tip: RadarTip(
                title: "Forecast",
                message: "Where this family is headed: threshold ETA extrapolated from measured velocity and acceleration, plus recurrence and staleness signals. Confidence rises with more samples, a cleaner trend fit, and a learned baseline — and falls for noisy data, freshly launched processes, and GC-style churn."
            ),
            accent: .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                    ForEach(cards) { card in
                        RadarChip(title: card.title, value: card.value, systemImage: card.systemImage, level: card.level)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(RadarStyle.color(for: level))
                        .accessibilityHidden(true)
                    Text(whyNow)
                }
                .font(.callout)
            }
        }
    }
}

struct FamilyCommandPanel: View {
    let commandLine: String
    let rootPID: Int32
    let actions: FamilyPageActions

    var body: some View {
        RadarSection(title: "Command Line", subtitle: "PID \(String(rootPID))", systemImage: "terminal") {
            Text(commandLine.isEmpty ? "Not available" : commandLine)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !commandLine.isEmpty {
                Button("Copy Command Line", systemImage: "doc.on.doc") {
                    actions.copy(commandLine, "Copied command line")
                }
                .controlSize(.small)
            }
        }
    }
}

struct FamilyForensicsPanel: View, Equatable {
    let forensics: FamilyForensicsSummary

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.forensics == rhs.forensics
    }

    var body: some View {
        RadarSection(
            title: "Forensics",
            subtitle: forensics.isPartial ? "partial" : "fresh",
            systemImage: "magnifyingglass",
            tip: RadarTip(
                title: "Forensics",
                message: "Deeper facts gathered on demand: working directory, open files, sockets, and listening ports. \"Partial\" means the scanner deferred some probes to stay inside its time budget — they refresh on the next pass."
            )
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                fact("Fresh", forensics.freshnessText)
                fact("Ports", forensics.portsText)
                fact("CWD", forensics.currentDirectory)
                fact("Root", forensics.rootDirectory)
                fact("Files", forensics.openFileText)
                fact("Sockets", forensics.socketText)
            }
            if !forensics.notes.isEmpty {
                FlowTags(title: "Notes", items: forensics.notes)
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
