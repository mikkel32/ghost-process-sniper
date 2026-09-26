import GhostProcessSniperCore
import SwiftUI

/// What the family page can do. Built once per body from the session, so
/// the page's sections never depend on the session themselves.
struct FamilyPageActions {
    let stop: () -> Void
    let stopProcess: (ProcessIdentity) -> Void
    let stopSupervisor: (KillSupervisor) -> Void
    let snooze: (TimeInterval) -> Void
    let ignore: () -> Void
    let unmute: () -> Void
    let copy: (_ text: String, _ toast: String) -> Void
    let copyPIDs: ([Int32]) -> Void
    let reveal: (_ executablePath: String) -> Void

    @MainActor
    init(session: RadarConsoleSession, family: ProcessFamily) {
        stop = { session.prepareKill(family) }
        stopProcess = { session.prepareKill(family, member: $0) }
        stopSupervisor = { session.prepareKill(supervisor: $0) }
        snooze = { session.snoozeSelected(minutes: $0) }
        ignore = { session.ignoreSelected() }
        unmute = { session.unmute(signatureID: family.signature.id, name: family.displayName) }
        copy = { session.copyToPasteboard($0, toast: $1) }
        copyPIDs = { session.copyPIDs($0) }
        reveal = { session.revealInFinder(executablePath: $0) }
    }
}

struct FamilyDetailConsoleView: View {
    let panel: FamilyDetailPanelModel
    /// What stopping this family would do, shown before any preview opens.
    let stopRisk: KillRiskAssessment
    let actions: FamilyPageActions
    /// Live dates from the family: a reused panel's own strings freeze at
    /// the time it was built.
    let lastScoredAt: Date?
    let forensicsFreshness: Date?

    @State private var selectedTab: FamilyDetailTab = .overview

    private var stopTitle: String {
        StopActionLabel.title(risk: stopRisk, memberCount: panel.members.count, appName: panel.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            FamilyDetailHeader(panel: panel, stopTitle: stopTitle, actions: actions)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

            Divider()

            HStack(spacing: 12) {
                Picker("Detail section", selection: $selectedTab) {
                    ForEach(FamilyDetailTab.allCases) { tab in
                        Label(tab.label, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                .layoutPriority(1)

                Spacer()

                Label(panel.change.summary, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(panel.change.level > .quiet ? RadarStyle.color(for: panel.change.level) : .secondary)
                    .lineLimit(1)
                    .help("How memory and CPU moved over the last half minute")
                Label(FamilyDetailPanelModel.lastScoredText(lastScoredAt), systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(RadarTheme.panel)

            Divider()

            if selectedTab == .processes {
                // The table scrolls itself; nesting it in a ScrollView would collapse it.
                FamilyProcessTreeTable(rows: panel.processTree, actions: actions)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        tabContent
                    }
                    .padding(18)
                }
            }
        }
        .background {
            LinearGradient(
                colors: [RadarTheme.accent(for: panel.level).opacity(0.06), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            FamilyDecisionHero(
                brief: panel.brief,
                risk: stopRisk,
                stopTitle: stopTitle,
                hasOwnedTargets: panel.hasOwnedTargets,
                actions: actions
            )
            FamilyTrendPanel(
                samples: panel.trendSamples,
                velocity: panel.trendVelocityMegabytesPerMinute,
                pattern: panel.memoryPattern,
                fitQuality: panel.trendFitQuality,
                hasFit: panel.trendPoints.count >= 4,
                cpuPercent: panel.cpuPercent,
                level: panel.level
            )
            .equatable()
            FamilyOverviewChips(
                memoryBytes: panel.memoryBytes,
                cpuPercent: panel.cpuPercent,
                velocity: panel.trendVelocityMegabytesPerMinute,
                baselineText: panel.brief.baselineText,
                level: panel.level
            )
            .equatable()
        case .evidence:
            FamilyScorePanel(components: panel.scoreComponents)
                .equatable()
            FamilyCulpritPanel(culprit: panel.culprit, level: panel.level)
                .equatable()
            FamilyForecastPanel(
                stateText: panel.forecastStateText,
                confidenceText: panel.forecastConfidenceText,
                whyNow: panel.forecastWhyNow,
                cards: panel.forecastCards,
                level: panel.forecastState.level
            )
            .equatable()
        case .processes:
            EmptyView()
        case .details:
            FamilyCommandPanel(commandLine: panel.commandLine, rootPID: panel.rootPID, actions: actions)
            FamilyForensicsPanel(forensics: panel.forensics, freshness: forensicsFreshness)
                .equatable()
        }
    }
}

private enum FamilyDetailTab: String, CaseIterable, Identifiable {
    case overview, evidence, processes, details

    var id: Self { self }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .evidence: "Evidence"
        case .processes: "Processes"
        case .details: "Details"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .evidence: "list.bullet.rectangle"
        case .processes: "point.3.connected.trianglepath.dotted"
        case .details: "doc.text.magnifyingglass"
        }
    }
}

private struct FamilyDetailHeader: View {
    let panel: FamilyDetailPanelModel
    let stopTitle: String
    let actions: FamilyPageActions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RadarBrandMark(level: panel.level, size: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(panel.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(panel.kind.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                Text(panel.commandLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    RadarStatusPill(title: panel.statusText, level: panel.level)
                    Text("PID \(String(panel.rootPID))")
                    if panel.members.count > 1 {
                        Text("\(panel.members.count) processes")
                    }
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(RadarFormat.bytes(panel.memoryBytes)).font(.title3.monospacedDigit().weight(.semibold))
                Text("CPU \(RadarFormat.percent(panel.cpuPercent))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Menu {
                    Button("Copy PIDs", systemImage: "number") { actions.copyPIDs(panel.members.map(\.pid)) }
                    Button("Copy Command Line", systemImage: "terminal") { actions.copy(panel.commandLine, "Copied command line") }
                    Button("Copy Name", systemImage: "textformat") { actions.copy(panel.title, "Copied \(panel.title)") }
                    if let rootPath = panel.processTree.first?.executablePath, !rootPath.isEmpty {
                        Divider()
                        Button("Reveal in Finder", systemImage: "folder") { actions.reveal(rootPath) }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Copy or reveal what this family runs")

                Button(stopTitle, systemImage: "stop.circle", role: .destructive, action: actions.stop)
                    .controlSize(.small)
                    .disabled(!panel.hasOwnedTargets)
                    .help(panel.hasOwnedTargets ? "Preview exactly what will be stopped, then confirm" : "No live processes owned by you to target")
            }
        }
        .padding(.vertical, 2)
    }
}
