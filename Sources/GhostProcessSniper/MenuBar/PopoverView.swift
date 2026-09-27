import AppKit
import GhostProcessSniperCore
import SwiftUI
import UserNotifications

/// Answers "what is hurting my Mac and what do I do" at a glance. The root
/// reads nothing from the monitor; each part observes only its own slice, so
/// a refresh redraws the temperature strip rather than the rows and menus.
struct PopoverView: View {
    let monitor: ProcessMonitor
    let notifier: UserNotificationRadarNotifier
    let onOpenConsole: () -> Void
    let onOpenFamily: (String) -> Void
    let quickStops: QuickStopAdvisor
    let onStop: (QuickStopAction) -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    var onOpenSecurity: () -> Void = {}
    var onOpenEnergy: () -> Void = {}
    var refreshesOnAppear = true

    var body: some View {
        VStack(spacing: 12) {
            PopoverVerdictBar(monitor: monitor)
            PopoverSecurityRow(monitor: monitor, onOpen: onOpenSecurity)
            PopoverEnergyRow(monitor: monitor, onOpen: onOpenEnergy)
            PopoverStoreWarning(monitor: monitor)
            PopoverCulprits(monitor: monitor, quickStops: quickStops, onOpenFamily: onOpenFamily, onStop: onStop)
            PopoverVitals(monitor: monitor)
            PopoverFooter(
                notifier: notifier,
                onOpenConsole: onOpenConsole,
                onOpenSettings: onOpenSettings,
                onQuit: onQuit
            )
        }
        .padding(14)
        .frame(width: 380)
        .tint(RadarTheme.brand)
        .background { PopoverBackdrop(monitor: monitor) }
        .task {
            if refreshesOnAppear {
                await monitor.refresh()
            }
        }
    }
}

/// One line while a suspicious or dangerous process or startup item needs a
/// look; nothing at all otherwise.
private struct PopoverSecurityRow: View {
    let monitor: ProcessMonitor
    let onOpen: () -> Void

    var body: some View {
        let report = monitor.sentinel
        let finding = report.findings.first { $0.isRunning && $0.severity >= .suspicious }
        let item = report.flaggedLaunchItems.first
        if finding != nil || item != nil {
            let severity = finding?.severity ?? item?.severity ?? .suspicious
            let tint = SentinelStyle.color(for: severity)
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.title3)
                        .foregroundStyle(tint.gradient)
                        .symbolEffect(.bounce, value: finding?.id ?? item?.id)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding?.headline ?? "Startup item: \(item?.label ?? "")")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(report.attentionCount > 1 ? "\(report.attentionCount) things need a look" : "Security needs a look")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("Review")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                .padding(10)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.75) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Security: \(finding?.headline ?? item?.label ?? ""). Review")
        }
    }
}

private struct PopoverBackdrop: View {
    let monitor: ProcessMonitor

    var body: some View {
        LinearGradient(
            colors: [RadarTheme.accent(for: monitor.statusLevel).opacity(0.09), .clear],
            startPoint: .topLeading,
            endPoint: .center
        )
    }
}

private struct PopoverVerdictBar: View {
    let monitor: ProcessMonitor

    @State private var isRefreshing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let compact = monitor.consoleSnapshot.compact
        let title = compact.intelligenceBrief.title
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Circle()
                    .fill(RadarTheme.accent(for: compact.commandCenter.level))
                    .frame(width: 9, height: 9)
                Text(title.isEmpty ? compact.commandCenter.statusText : title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(MenuBarStatusPresentation.compactStateText(summary: monitor.summary))

            Spacer(minLength: 8)

            Button {
                refresh()
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, isActive: isRefreshing && !reduceMotion)
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "Scanning processes" : "Scan now")
            .help("Scan now (⌘R)")
            .keyboardShortcut("r")
        }
    }

    private func refresh() {
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
}

private struct PopoverStoreWarning: View {
    let monitor: ProcessMonitor

    var body: some View {
        if let message = monitor.storeError {
            PopoverStoreWarningRow(message: message)
        }
    }
}

private struct PopoverStoreWarningRow: View {
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("History is not being saved")
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Reads only the content-gated console snapshot and Quick Stop actions, so
/// rows and their context menus rebuild when the findings change, not on
/// every sample.
private struct PopoverCulprits: View {
    let monitor: ProcessMonitor
    let quickStops: QuickStopAdvisor
    let onOpenFamily: (String) -> Void
    let onStop: (QuickStopAction) -> Void

    var body: some View {
        let compact = monitor.consoleSnapshot.compact
        let risk = Array(compact.topRiskRows.prefix(3))
        let warnings = Array(compact.warmingRows.prefix(2))
        VStack(alignment: .leading, spacing: 6) {
            if !risk.isEmpty {
                rows(risk, showsStopButton: true)
            } else if !warnings.isEmpty {
                Text("EARLY WARNINGS")
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                // Early warnings are not stop-worthy yet: the action lives in the menu.
                rows(warnings, showsStopButton: false)
            } else {
                PopoverQuietState(familyCount: compact.allRows.count, hasSampled: compact.hasSampled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .radarSurface(tint: RadarTheme.accent(for: compact.commandCenter.level), cornerRadius: 14)
    }

    private func rows(_ rows: [CompactSidebarRowModel], showsStopButton: Bool) -> some View {
        VStack(spacing: 4) {
            ForEach(rows) { row in
                let quickStop = quickStops.actions[row.id].flatMap { $0.isAvailable ? $0 : nil }
                HStack(spacing: 6) {
                    Button {
                        onOpenFamily(row.id)
                    } label: {
                        PopoverCulpritRow(row: row)
                    }
                    .buttonStyle(.plain)
                    if showsStopButton, let quickStop {
                        QuickStopButton(action: quickStop) { onStop(quickStop) }
                            .labelStyle(.titleOnly)
                            .controlSize(.small)
                    }
                }
                .contextMenu {
                    Button {
                        onOpenFamily(row.id)
                    } label: {
                        Label("Show in Console", systemImage: "rectangle.3.group")
                    }
                    Menu {
                        FamilySnoozeMenu { minutes in
                            Task { await monitor.snooze(signatureID: row.id, minutes: minutes) }
                        }
                    } label: {
                        Label("Snooze", systemImage: "moon")
                    }
                    Button {
                        Task { await monitor.ignore(signatureID: row.id) }
                    } label: {
                        Label("Ignore Family", systemImage: "eye.slash")
                    }
                    if let quickStop {
                        Divider()
                        Button(role: .destructive) {
                            onStop(quickStop)
                        } label: {
                            Label(quickStop.title, systemImage: quickStop.systemImage)
                        }
                    }
                }
                if row.id != rows.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct PopoverQuietState: View {
    let familyCount: Int
    let hasSampled: Bool

    var body: some View {
        HStack(spacing: 10) {
            // No green seal before the first scan: nothing is known to be quiet yet.
            if !hasSampled {
                RadarWaitLabel("Scanning your processes…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(.green.gradient)
                    .accessibilityHidden(true)
                Text(familyCount == 0
                     ? "Nothing in scope to watch. Widen it to Heavy or All in Settings."
                     : "\(familyCount) families watched, nothing misbehaving")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }
}

private struct PopoverCulpritRow: View {
    let row: CompactSidebarRowModel

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: row.systemImage)
                .foregroundStyle(RadarStyle.color(for: row.level))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ScoreCapsuleBadge(scoreText: row.statusText, level: row.level)
                }
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(row.metricText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovering ? 1 : 0.5)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 5)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .help(row.helpText)
        .accessibilityElement(children: .combine)
    }
}

/// Temperatures change every sample and pressure only occasionally, so each
/// is read by its own view.
private struct PopoverVitals: View {
    let monitor: ProcessMonitor

    var body: some View {
        HStack(spacing: 12) {
            PopoverThermalReadings(monitor: monitor)
            Spacer(minLength: 4)
            PopoverPressureReading(monitor: monitor)
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .radarSurface(tint: RadarTheme.brand, cornerRadius: 12)
    }
}

private struct PopoverThermalReadings: View {
    let monitor: ProcessMonitor

    var body: some View {
        let thermals = monitor.thermals
        HStack(spacing: 12) {
            Label("CPU \(thermals.temperatureText(thermals.cpuCelsius))", systemImage: "cpu")
            Label("GPU \(thermals.temperatureText(thermals.gpuCelsius))", systemImage: "thermometer.medium")
        }
        .lineLimit(1)
    }
}

private struct PopoverPressureReading: View {
    let monitor: ProcessMonitor

    var body: some View {
        let pressure = monitor.systemPressure
        Label {
            Text("Memory \(pressure.isKnown ? pressure.level.label : "—")")
                .foregroundStyle(pressure.level == .nominal ? AnyShapeStyle(.primary) : AnyShapeStyle(RadarStyle.color(for: pressure.level.ghostLevel)))
        } icon: {
            Image(systemName: "memorychip")
        }
        .lineLimit(1)
        .help("System memory pressure")
    }
}

private struct PopoverFooter: View {
    let notifier: UserNotificationRadarNotifier
    let onOpenConsole: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var notificationStatus: UNAuthorizationStatus?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpenConsole) {
                Label("Open Dashboard", systemImage: "rectangle.3.group")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("o")

            Spacer()

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")
            .help("Settings (⌘,)")

            Menu {
                if notificationStatus == .notDetermined {
                    Button("Allow Notifications…") {
                        Task {
                            _ = await notifier.requestAuthorization()
                            notificationStatus = await notifier.authorizationStatus()
                        }
                    }
                    Divider()
                } else if notificationStatus == .denied {
                    Button("Open Notification Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Divider()
                }
                Button("Quit Ghost Process Sniper", action: onQuit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .accessibilityLabel("More")
            .help("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .radarSurface(tint: RadarTheme.brand, cornerRadius: 12)
        .task {
            notificationStatus = await notifier.authorizationStatus()
        }
    }
}

#if DEBUG
// PreviewProvider rather than #Preview: the macro plugin is not guaranteed
// under a command-line `swift build`. Fixtures use an in-memory monitor.
struct PopoverView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            popover(.quiet).previewDisplayName("Quiet")
            popover(.earlyWarning).previewDisplayName("Early warning")
            popover(.hot).previewDisplayName("Hot")
            PopoverStoreWarningRow(message: "The radar database could not be opened.")
                .padding(14)
                .frame(width: 380)
                .previewDisplayName("Store error")
        }
    }

    private enum Scenario {
        case quiet, earlyWarning, hot
    }

    @MainActor
    private static func popover(_ scenario: Scenario) -> some View {
        let fixture = ProcessMonitor(builder: ProcessFamilyBuilder(currentUserID: 501), store: nil)
        let quickStops = QuickStopAdvisor(monitor: fixture)
        return PopoverView(
            monitor: fixture,
            notifier: UserNotificationRadarNotifier(),
            onOpenConsole: {},
            onOpenFamily: { _ in },
            quickStops: quickStops,
            onStop: { _ in },
            onOpenSettings: {},
            onQuit: {},
            refreshesOnAppear: false
        )
        // ingest runs the refresh worker, so the fixture fills in once the preview appears.
        .task {
            await feed(fixture, scenario, quickStops: quickStops)
        }
    }

    @MainActor
    private static func feed(_ monitor: ProcessMonitor, _ scenario: Scenario, quickStops: QuickStopAdvisor) async {
        let start = Date()
        for step in 0..<6 {
            let now = start.addingTimeInterval(Double(step) * 5)
            let helper = process(502, "python3", memoryMB: 90, cpu: 0.5, startedAt: start.addingTimeInterval(-120), at: now)
            let main: ProcessMetrics = switch scenario {
            case .quiet: process(501, "node", memoryMB: 180, cpu: 1, startedAt: start.addingTimeInterval(-120), at: now)
            // A dev server left running for days reads as forgotten.
            case .earlyWarning: process(501, "vite", memoryMB: 300, cpu: 0.2, startedAt: start.addingTimeInterval(-3 * 86_400), at: now)
            case .hot: process(501, "node", memoryMB: 900, cpu: 45, startedAt: start.addingTimeInterval(-120), at: now)
            }
            await monitor.ingest([main, helper], now: now)
        }
        quickStops.update()
    }

    private static func process(
        _ pid: Int32,
        _ name: String,
        memoryMB: UInt64,
        cpu: Double,
        startedAt: Date,
        at date: Date
    ) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: UInt64(startedAt.timeIntervalSince1970), startTimeMicroseconds: 0),
            parentPID: 1, userID: 501, ownerName: "you", name: name,
            executablePath: "/usr/local/bin/\(name)", commandLine: "\(name) server.js",
            residentMemoryBytes: memoryMB * 1_048_576, physicalFootprintBytes: memoryMB * 1_048_576,
            virtualMemoryBytes: memoryMB * 2_097_152, cpuPercent: cpu, totalProcessorSeconds: 100,
            threadCount: 8, isSystemProcess: false, sampledAt: date
        )
    }
}
#endif
