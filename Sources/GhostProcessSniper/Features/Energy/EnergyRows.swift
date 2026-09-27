import GhostProcessSniperCore
import SwiftUI

enum EnergyStyle {
    static func color(for severity: EnergyFindingSeverity) -> Color {
        switch severity {
        case .notable: .yellow
        case .attention: .orange
        }
    }

    static func symbol(for kind: EnergyFindingKind) -> String {
        switch kind {
        case .keepsMacAwake: "moon.zzz.fill"
        case .idleWakeups: "alarm.waves.left.and.right.fill"
        case .heavyDiskWrites: "internaldrive.fill"
        case .batteryDrain: "battery.25percent"
        }
    }

    static func kindLabel(_ consumer: EnergyConsumer) -> String {
        let count = consumer.processCount == 1 ? "1 process" : "\(consumer.processCount) processes"
        switch consumer.kind {
        case .app: return "App · \(count)"
        case .job: return consumer.hostAppName.map { "Job in \($0) · \(count)" } ?? "Job · \(count)"
        case .knownSource(let source): return source.displayName
        case .process: return consumer.isSystem ? "macOS service" : "Process"
        }
    }
}

struct EnergyTag: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((color == .secondary ? Color.primary : color).opacity(0.08), in: Capsule())
    }
}

/// One app or job: its energy with a bar relative to the heaviest, wake-ups,
/// disk writes, and the battery time stopping it would give back.
struct EnergyConsumerRow: View {
    let consumer: EnergyConsumer
    let showsEnergy: Bool
    let maximumWatts: Double
    let actions: EnergyActions

    var body: some View {
        HStack(spacing: 12) {
            ThermalAppIcon(path: consumer.applicationPath, isSystemProcess: consumer.isSystem, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(consumer.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(EnergyStyle.kindLabel(consumer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            if showsEnergy {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(EnergyFormat.watts(consumer.averageWatts))
                        .font(.callout.monospacedDigit().weight(.semibold))
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.yellow.gradient)
                            .frame(width: max(2, proxy.size.width * min(1, consumer.averageWatts / max(maximumWatts, 0.01))))
                    }
                    .frame(width: 64, height: 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .frame(width: 76, alignment: .trailing)
            }
            metric(EnergyFormat.rate(consumer.idleWakeupsPerSecond), caption: "wake-ups",
                   highlighted: consumer.idleWakeupsPerSecond >= 150)
            metric(EnergyFormat.bytes(consumer.diskWriteBytesPerSecond) + "/s", caption: "writes",
                   highlighted: consumer.diskWriteBytesPerSecond >= 1_800_000)
            if let gained = consumer.batteryMinutesGained, gained >= 1 {
                Text("+\(EnergyFormat.duration(gained * 60))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 70, alignment: .trailing)
                    .help("About this much more battery if \(consumer.displayName) stopped, at the current draw")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if let key = consumer.familyKey { actions.open(key) } }
        .contextMenu {
            if let key = consumer.familyKey {
                Button("Open Family") { actions.open(key) }
                Button("Stop\u{2026}") { actions.stop(key, consumer.displayName) }
            }
            if let path = consumer.applicationPath {
                Button("Show in Finder") { actions.reveal(path) }
            }
        }
        .accessibilityElement(children: .combine)
        .help(consumer.canInspectFamily ? "Click to open \(consumer.displayName)\u{2019}s family" : consumer.displayName)
    }

    private func metric(_ value: String, caption: String, highlighted: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.caption.monospacedDigit().weight(highlighted ? .bold : .regular))
                .foregroundStyle(highlighted ? Color.orange : Color.primary)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 70, alignment: .trailing)
    }
}

struct SleepBlockerRow: View {
    let blocker: SleepBlocker
    let actions: EnergyActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 10) {
                Image(systemName: blocker.effect == .displaySleep ? "display" : "moon.zzz")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(blocker.isSystem || blocker.isIntentional ? Color.secondary : Color.orange)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(blocker.displayName)
                            .font(.callout.weight(.semibold))
                        if blocker.isIntentional {
                            Text("Keep-awake app")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if let held = blocker.heldFor(at: context.date) {
                    Text(EnergyFormat.duration(held))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(held >= 1_800 && !blocker.isSystem && !blocker.isIntentional ? Color.orange : Color.secondary)
                        .help("Held since \(blocker.heldSince?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                }
            }
            .padding(.vertical, 5)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let key = blocker.familyKey {
                Button("Open Family") { actions.open(key) }
                Button("Stop\u{2026}") { actions.stop(key, blocker.displayName) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var text = blocker.effect == .displaySleep ? "Keeps the display on · " : "Keeps the Mac from sleeping · "
        text += blocker.reason
        if let via = blocker.viaProcessName { text += " (held by \(via))" }
        if blocker.isIdle { text += " · idle" }
        return text
    }
}

/// An energy finding: what, the evidence and one next step.
struct EnergyFindingCard: View {
    let finding: EnergyFinding
    let actions: EnergyActions

    private var tint: Color { EnergyStyle.color(for: finding.severity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: EnergyStyle.symbol(for: finding.kind))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint.gradient)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.headline)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(finding.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Label(finding.advice, systemImage: "lightbulb")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let key = finding.familyKey {
                HStack(spacing: 8) {
                    Button("Open Family") { actions.open(key) }
                    Button("Stop\u{2026}") { actions.stop(key, finding.displayName) }
                        .help("Opens the stop preview; nothing stops without confirmation")
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .radarSurface(tint: tint, cornerRadius: 16)
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                .fill(tint.gradient)
                .frame(width: 4)
        }
        .accessibilityElement(children: .contain)
    }
}

struct SidebarEnergyDestination: View {
    let session: RadarConsoleSession
    let namespace: Namespace.ID

    var body: some View {
        let glance = session.monitor.energyGlance
        let isSelected = session.state.focusedSelection == .energy
        let top = glance.topFinding
        Button { session.focus(.energy) } label: {
            SidebarDestinationRow(
                title: "Energy",
                subtitle: subtitle(glance),
                systemImage: top.map { EnergyStyle.symbol(for: $0.kind) } ?? "bolt.fill",
                color: top.map { EnergyStyle.color(for: $0.severity) } ?? RadarTheme.brand,
                isSelected: isSelected
            )
            .background {
                RadarSelectionSurface(selected: isSelected, namespace: namespace, key: "main-destination")
            }
        }
        .buttonStyle(RadarRowButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func subtitle(_ glance: EnergyGlance) -> String {
        if glance.findings.count > 1 { return "\(glance.findings.count) things worth a look" }
        if let top = glance.topFinding { return top.displayName + " · worth a look" }
        if let name = glance.topConsumerName, let watts = glance.topConsumerWatts {
            return "\(name) leads at \(EnergyFormat.watts(watts))"
        }
        return glance.batteryLine ?? "Battery, sleep and power use"
    }
}

/// Shown above the Overview verdict only while an energy finding needs
/// attention, such as an idle app holding the Mac awake for hours.
struct EnergyOverviewBanner: View {
    let session: RadarConsoleSession

    var body: some View {
        let glance = session.monitor.energyGlance
        if let top = glance.findings.first(where: { $0.severity == .attention }) {
            let tint = EnergyStyle.color(for: top.severity)
            Button { session.focus(.energy) } label: {
                HStack(spacing: 12) {
                    Image(systemName: EnergyStyle.symbol(for: top.kind))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tint.gradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ENERGY · WORTH A LOOK")
                            .font(.system(size: 9, weight: .black))
                            .tracking(1.1)
                            .foregroundStyle(tint)
                        Text(top.headline)
                            .font(.headline)
                            .lineLimit(1)
                        Text(top.advice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text("Review")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tint)
                }
                .padding(14)
                .radarSurface(tint: tint, cornerRadius: 16)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Energy page")
        }
    }
}
