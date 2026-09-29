import AppKit
import GhostProcessSniperCore
import SwiftUI

/// The Security page: live findings, the privacy sensors and every new
/// process, newest first. It observes only the Sentinel report, which is
/// republished only when its content changes.
struct SentinelConsoleView: View {
    let session: RadarConsoleSession
    @State private var focusedLaunch: LaunchEvent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var report: SentinelReport { session.monitor.sentinel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SentinelHero(report: report)
                SentinelSensorStrip(sensors: report.sensors)
                findings
                SentinelStartupItems(items: report.launchItems)
                SentinelTrustedList(entries: report.trusted) { session.monitor.revokeSentinelTrust($0.id) }
                SentinelLaunchFeed(launches: report.launches, perMinute: report.launchesLastMinute) { event in
                    focusedLaunch = event
                }
            }
            .padding(24)
        }
        .sheet(item: $focusedLaunch) { event in
            SentinelLaunchDetail(event: event, finding: report.findings.first { $0.identity == event.identity },
                                 actions: actions) { focusedLaunch = nil }
        }
    }

    @ViewBuilder private var findings: some View {
        let list = report.findings
        if list.isEmpty {
            RadarSection(title: "Findings", subtitle: "Nothing needs attention",
                         systemImage: "checkmark.shield", accent: .green) {
                Text("Sentinel checks every process for attack patterns: apps launching shells, pasted commands that download and run code, hidden payloads, fake password prompts, keychain and cookie theft, masquerading system names, unsigned programs in odd places, miners and reverse shells.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Findings")
                        .font(.headline)
                    Text("\(list.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    Spacer()
                    if report.dismissedCount > 0 {
                        Text("\(report.dismissedCount) dismissed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(list) { finding in
                    SentinelFindingCard(finding: finding, actions: actions)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.16), value: list.map(\.id))
        }
    }

    private var actions: SentinelFindingActions {
        SentinelFindingActions(
            stop: { finding in
                focusedLaunch = nil
                session.prepareKill(processIdentity: finding.identity, name: finding.name)
            },
            reveal: { finding in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.executablePath)])
            },
            copy: { finding in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.report(for: finding), forType: .string)
                session.toast = RadarToast(message: "Finding copied", systemImage: "doc.on.doc")
            },
            trust: { finding in
                Task {
                    guard let entry = await session.monitor.trustSentinelFinding(finding.id) else {
                        // The finding expired between the card being drawn and the click.
                        session.toast = RadarToast(message: "Nothing to trust here; the finding has expired",
                                                   systemImage: "questionmark.circle")
                        return
                    }
                    session.toast = RadarToast(message: "Trusted: \(entry.scope)", systemImage: "checkmark.shield")
                }
            },
            dismiss: { finding in
                session.monitor.dismissSentinelFinding(finding.id)
            },
            openFamily: { finding in
                if let family = family(containing: finding.identity) {
                    session.focus(.family(family.familyKey))
                } else {
                    session.toast = RadarToast(message: "\(finding.name) is not part of a tracked family; search finds it by PID \(finding.identity.pid)",
                                               systemImage: "magnifyingglass")
                }
            }
        )
    }

    private func family(containing identity: ProcessIdentity) -> ProcessFamily? {
        session.monitor.families.first { family in family.members.contains { $0.identity == identity } }
    }

    static func report(for finding: SentinelFinding) -> String {
        var lines = [
            "Ghost Process Sniper — Sentinel finding",
            "\(finding.severity.label): \(finding.headline)",
            "Process: \(finding.name) (PID \(finding.identity.pid))",
            "Path: \(finding.executablePath)",
            "Launched by: \(finding.lineageText)",
            "Command: \(finding.commandLine)",
        ]
        if let signing = finding.signing { lines.append("Signature: \(signing.label)") }
        if let source = finding.downloadedFrom.first { lines.append("Downloaded from: \(source)") }
        if !finding.connections.isEmpty { lines.append("Connected to: \(finding.connections.joined(separator: ", "))") }
        lines.append("Evidence:")
        for signal in finding.signals {
            lines.append("- [\(signal.severity.label)] \(signal.kind.title): \(signal.detail)" + (signal.evidence.map { " — \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

/// The page header: a shield that answers "am I OK?" at a glance and sends
/// out one ripple each time a new process starts. No continuous animation.
struct SentinelHero: View {
    let report: SentinelReport
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var severity: SentinelSeverity? { report.displaySeverity }
    private var tint: Color { severity.map(SentinelStyle.color(for:)) ?? .green }

    private var title: String {
        let active = report.findings.filter { $0.isRunning && $0.severity >= .suspicious }
        let startup = report.flaggedLaunchItems.count
        let exited = report.exitedDangerousCount
        if active.isEmpty, exited > 0 {
            // Over already, but it ran: the card below says what it was.
            return exited == 1 ? "A dangerous command ran and has already exited"
                : "\(exited) dangerous commands ran and have already exited"
        }
        if active.isEmpty, startup > 0 {
            return startup == 1 ? "1 startup item to review" : "\(startup) startup items to review"
        }
        switch severity {
        case .dangerous?: return active.count == 1 ? "Act now: 1 dangerous process" : "Act now: \(active.count) processes need you"
        case .suspicious?: return active.count == 1 ? "1 suspicious process to review" : "\(active.count) suspicious processes to review"
        case .notable?: return "Nothing suspicious, a few things to know"
        default: return "Nothing suspicious running"
        }
    }

    private var subtitle: String {
        let apps = report.watchedAppNames
        let watching: String
        switch apps.count {
        case 0: watching = "Checking every new process"
        case 1...3: watching = "Watching \(apps.joined(separator: ", ")) live for new processes"
        default: watching = "Watching \(apps.prefix(2).joined(separator: ", ")) and \(apps.count - 2) more apps live"
        }
        return watching + " · \(report.launchesLastMinute) started in the last minute"
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.5), lineWidth: 2)
                    .frame(width: 58, height: 58)
                    .keyframeAnimator(initialValue: RippleValue(), trigger: report.launches.first?.id) { ring, value in
                        ring.scaleEffect(value.scale).opacity(value.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(1.0, duration: 0.01)
                            CubicKeyframe(1.9, duration: 0.9)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(reduceMotion ? 0 : 0.8, duration: 0.01)
                            LinearKeyframe(0, duration: 0.9)
                        }
                    }
                Image(systemName: severity.map { $0 >= .suspicious ? "exclamationmark.shield.fill" : "checkmark.shield.fill" } ?? "checkmark.shield.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(tint.gradient)
                    .frame(width: 58, height: 58)
                    .background(tint.opacity(0.12), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SENTINEL")
                    .font(.system(size: 9, weight: .black))
                    .tracking(1.2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .radarSurface(tint: tint, cornerRadius: 18)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: severity)
        .accessibilityElement(children: .combine)
    }

    private struct RippleValue {
        var scale = 1.0
        var opacity = 0.0
    }
}

/// Microphone and camera, stated as plainly as macOS allows.
struct SentinelSensorStrip: View {
    let sensors: PrivacySensorState

    var body: some View {
        AdaptivePairLayout(breakpoint: 560) {
            tile(
                title: "Microphone",
                systemImage: sensors.microphoneActive ? "mic.fill" : "mic.slash",
                active: sensors.microphoneNeedsAttention,
                detail: microphoneDetail
            )
            tile(
                title: "Camera",
                systemImage: sensors.cameraActive ? "video.fill" : "video.slash",
                active: sensors.cameraActive,
                detail: sensors.cameraActive
                    ? "On (\(sensors.cameraDeviceNames.joined(separator: ", "))). macOS does not say which app is using it."
                    : "Off"
            )
        }
    }

    private var microphoneDetail: String {
        guard sensors.available else { return "Checking…" }
        // Only Siri, holding the microphone open until it hears its wake phrase: the tile stays calm.
        if sensors.microphoneIsPassive { return "Siri is waiting for \u{201C}Hey Siri\u{201D}" }
        if !sensors.microphoneUsers.isEmpty {
            return "In use by " + sensors.microphoneUsers.map(\.name).joined(separator: ", ")
        }
        return sensors.microphoneActive ? "In use" : "Off"
    }

    private func tile(title: String, systemImage: String, active: Bool, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(active ? Color.orange : .secondary)
                .frame(width: 36, height: 36)
                .background((active ? Color.orange : Color.primary).opacity(active ? 0.14 : 0.06), in: Circle())
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .radarSurface(tint: active ? .orange : RadarTheme.brand, cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

/// A launch in full: the chain, the command, and its finding if any.
struct SentinelLaunchDetail: View {
    let event: LaunchEvent
    let finding: SentinelFinding?
    let actions: SentinelFindingActions
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SentinelProgramIcon(path: event.executablePath, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.name).font(.title3.weight(.semibold))
                    Text("Started \(event.at.formatted(date: .omitted, time: .standard)) · PID \(String(event.identity.pid))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            if let finding {
                SentinelFindingCard(finding: finding, actions: actions)
            } else {
                SentinelLineageView(lineage: event.lineage, tint: RadarTheme.brand)
                Text(event.commandLine)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(event.executablePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Label("Nothing about this launch matched an attack pattern.", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

/// The sidebar's Security entry. Its colour and line answer "is anything
/// wrong?" without opening the page.
struct SidebarSecurityDestination: View {
    let session: RadarConsoleSession
    let namespace: Namespace.ID

    var body: some View {
        let report = session.monitor.sentinel
        let severity = report.displaySeverity
        let isSelected = session.state.focusedSelection == .security
        Button { session.focus(.security) } label: {
            SidebarDestinationRow(
                title: "Security",
                subtitle: report.attentionLine
                    ?? (report.watchedAppNames.isEmpty ? "Watching every new process" : "Watching \(report.watchedAppNames.count) apps live"),
                systemImage: (severity ?? .info) >= .suspicious ? "exclamationmark.shield.fill" : "checkmark.shield",
                color: (severity ?? .info) >= .suspicious ? SentinelStyle.color(for: severity ?? .info) : RadarTheme.brand,
                isSelected: isSelected
            )
            .background {
                RadarSelectionSurface(selected: isSelected, namespace: namespace, key: "main-destination")
            }
        }
        .buttonStyle(RadarRowButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Shown above the Overview verdict only while a suspicious or dangerous
/// process is running; otherwise it takes no space at all.
struct SentinelOverviewBanner: View {
    let session: RadarConsoleSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let report = session.monitor.sentinel
        let live = report.findings.filter { $0.isRunning && $0.severity >= .suspicious }
        ZStack {
            if live.isEmpty, let gone = report.latestExitedDangerous {
                // Over already, but it ran: the page below says what it did.
                let tint = SentinelStyle.color(for: .dangerous)
                Button { session.focus(.security) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(tint.gradient)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SECURITY · A DANGEROUS COMMAND RAN")
                                .font(.system(size: 9, weight: .black))
                                .tracking(1.1)
                                .foregroundStyle(tint)
                            Text(gone.headline)
                                .font(.headline)
                                .lineLimit(1)
                            Text("It had already exited when Ghost caught it. Review what it did.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("Review")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(tint.opacity(0.16), in: Capsule())
                    }
                    .padding(14)
                    .radarSurface(tint: tint, cornerRadius: 16)
                }
                .buttonStyle(RadarCardButtonStyle(tint: tint))
            } else if let top = live.first {
                let tint = SentinelStyle.color(for: top.severity)
                Button { session.focus(.security) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(tint.gradient)
                            .symbolEffect(.bounce, value: top.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(top.severity == .dangerous ? "SECURITY · ACT NOW" : "SECURITY · WORTH A LOOK")
                                .font(.system(size: 9, weight: .black))
                                .tracking(1.1)
                                .foregroundStyle(tint)
                            Text(top.headline)
                                .font(.headline)
                                .lineLimit(1)
                            Text(live.count > 1 ? "\(top.lineageText) · and \(live.count - 1) more" : top.lineageText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("Review")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(tint.opacity(0.16), in: Capsule())
                    }
                    .padding(14)
                    .radarSurface(tint: tint, cornerRadius: 16)
                }
                .buttonStyle(RadarCardButtonStyle(tint: tint))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: live.first?.id)
    }
}
