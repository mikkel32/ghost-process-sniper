import AppKit
import Charts
import GhostProcessSniperCore
import SwiftUI

/// The Energy page: the battery and the Mac's draw, what uses energy, what
/// keeps the Mac awake, and anything worth doing about it. It observes only
/// the energy report, which the worker prepares once per scan.
struct EnergyConsoleView: View {
    let session: RadarConsoleSession
    @State private var showsSystemBlockers = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var report: EnergyReport { session.monitor.energy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EnergyHero(report: report)
                findings
                consumers
                blockers
                Text(coverageNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    private var actions: EnergyActions {
        EnergyActions(
            open: { key in session.focus(.family(key)) },
            stop: { key, name in session.prepareKill(familyKey: key, name: name) },
            reveal: { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        )
    }

    @ViewBuilder private var findings: some View {
        if !report.findings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Worth a look")
                        .font(.headline)
                    Text("\(report.findings.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    Spacer()
                }
                ForEach(report.findings) { finding in
                    EnergyFindingCard(finding: finding, actions: actions)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.16), value: report.findings.map(\.id))
        }
    }

    private var consumers: some View {
        let running = report.consumers.filter(\.isRunning)
        let exited = report.consumers.filter { !$0.isRunning && $0.lastHourWattHours >= 0.05 }
        return RadarSection(
            title: report.perProcessEnergy ? "Using energy now" : "Waking the Mac and writing to disk",
            subtitle: report.perProcessEnergy ? "Averaged over the last 5 minutes" : nil,
            systemImage: "bolt.fill", accent: .yellow
        ) {
            if running.isEmpty {
                Text("Measuring… energy appears after two scans.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(running.prefix(12)) { consumer in
                        EnergyConsumerRow(consumer: consumer, showsEnergy: report.perProcessEnergy,
                                          maximumWatts: running.first?.averageWatts ?? 1, actions: actions)
                        if consumer.id != running.prefix(12).last?.id { Divider().opacity(0.5) }
                    }
                }
                if !exited.isEmpty {
                    Text("Exited in the last hour: " + exited.prefix(4).map {
                        "\($0.displayName) \(EnergyFormat.wattHours($0.lastHourWattHours))"
                    }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var blockers: some View {
        let unexpected = report.blockers.filter { !$0.isSystem && !$0.isIntentional }
        let intentional = report.blockers.filter { !$0.isSystem && $0.isIntentional }
        let system = report.blockers.filter(\.isSystem)
        return RadarSection(
            title: "Keeping your Mac awake",
            subtitle: unexpected.isEmpty ? "Nothing unexpected" : nil,
            systemImage: "moon.zzz.fill", accent: unexpected.isEmpty ? .indigo : .orange
        ) {
            VStack(alignment: .leading, spacing: 2) {
                if unexpected.isEmpty && intentional.isEmpty {
                    Text("No app is holding your Mac awake. It can sleep on its usual schedule.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(unexpected + intentional) { blocker in
                    SleepBlockerRow(blocker: blocker, actions: actions)
                }
                if !system.isEmpty {
                    DisclosureGroup(isExpanded: $showsSystemBlockers) {
                        ForEach(system) { blocker in
                            SleepBlockerRow(blocker: blocker, actions: actions)
                        }
                    } label: {
                        Text(system.count == 1 ? "1 macOS service" : "\(system.count) macOS services")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var coverageNote: String {
        var note = "Energy is what macOS attributes to each process\u{2019}s CPU work, measured for \(report.measuredProcessCount) processes; the display, graphics and other hardware make up the rest of the Mac\u{2019}s draw."
        if !report.perProcessEnergy {
            note = "This Mac does not report energy per process, so apps are ranked by processor wake-ups and disk writes."
        }
        return note + " Nothing here is stopped without the usual preview."
    }
}

struct EnergyActions {
    let open: (String) -> Void
    let stop: (String, String) -> Void
    let reveal: (String) -> Void
}

/// The battery, the Mac's draw and the last hour of measured energy.
struct EnergyHero: View {
    let report: EnergyReport

    private var battery: BatteryOutlook? { report.battery }

    private var tint: Color {
        if let top = report.topFinding { return top.severity == .attention ? .orange : .yellow }
        if let minutes = battery?.minutesRemaining, minutes < 20 { return Color(nsColor: .systemRed) }
        return .green
    }

    private var symbol: String {
        guard let battery, let charge = battery.chargePercent else { return "bolt.fill" }
        if !battery.isDischarging { return "battery.100percent.bolt" }
        return switch charge {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }

    private var title: String {
        guard let battery else { return "Energy use" }
        if battery.isDischarging {
            if let minutes = battery.minutesRemaining {
                return "About \(EnergyFormat.duration(minutes * 60)) of battery left"
            }
            return battery.chargePercent.map { "On battery · \(Int($0.rounded()))%" } ?? "On battery"
        }
        guard let charge = battery.chargePercent else {
            return battery.drawWatts.map { "Drawing \(EnergyFormat.watts($0))" } ?? "Energy use"
        }
        return battery.isCharging ? "Charging · \(Int(charge.rounded()))%" : "Plugged in · \(Int(charge.rounded()))%"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let draw = battery?.drawWatts {
            parts.append("Your Mac is drawing \(EnergyFormat.watts(draw))")
        }
        if report.perProcessEnergy, report.measuredWatts > 0 {
            parts.append("apps and jobs account for \(EnergyFormat.watts(report.measuredWatts)) of it")
        }
        let awake = report.unexpectedBlockers.count
        if awake > 0 { parts.append(awake == 1 ? "1 app is keeping it awake" : "\(awake) apps are keeping it awake") }
        return parts.isEmpty ? "Measuring energy for every process" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(tint.gradient)
                    .frame(width: 58, height: 58)
                    .background(tint.opacity(0.12), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 4) {
                    Text("ENERGY")
                        .font(.system(size: 9, weight: .black))
                        .tracking(1.2)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if report.perProcessEnergy, report.minuteWatts.count >= 2 {
                    sparkline
                }
            }
            if let battery, battery.healthPercent != nil || battery.cycleCount != nil || battery.adapterInputWatts != nil {
                WrappingHStack(spacing: 6) {
                    if let health = battery.healthPercent {
                        EnergyTag(text: "Battery health \(Int(health.rounded()))%", systemImage: "heart.fill",
                                  color: health < 80 ? .orange : .green)
                    }
                    if let cycles = battery.cycleCount {
                        EnergyTag(text: "\(cycles) cycles", systemImage: "arrow.triangle.2.circlepath", color: .secondary)
                    }
                    if let adapter = battery.adapterInputWatts, adapter > 0 {
                        EnergyTag(text: "Charger \(EnergyFormat.watts(adapter))", systemImage: "powerplug.fill",
                                  color: .secondary)
                    }
                }
            }
        }
        .padding(16)
        .radarSurface(tint: tint, cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }

    private var sparkline: some View {
        let points = Array(report.minuteWatts.enumerated())
        return VStack(alignment: .trailing, spacing: 3) {
            Chart(points, id: \.offset) { point in
                AreaMark(x: .value("Minute", point.offset), y: .value("Watts", point.element))
                    .foregroundStyle(.yellow.opacity(0.25).gradient)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Minute", point.offset), y: .value("Watts", point.element))
                    .foregroundStyle(.yellow)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 150, height: 44)
            Text("Last hour · \(EnergyFormat.wattHours(report.lastHourWattHours))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Measured process energy over the last hour: \(EnergyFormat.wattHours(report.lastHourWattHours))")
    }
}
