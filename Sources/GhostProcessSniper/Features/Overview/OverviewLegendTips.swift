import GhostProcessSniperCore
import SwiftUI

/// Opens its popover after a short hover, like InfoTip, and on click, Return
/// or VoiceOver activation, so it is not a pointer-only control.
private struct HoverPopoverTrigger: ViewModifier {
    @Binding var isPresented: Bool
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: hovering ? 220_000_000 : 150_000_000)
                    guard !Task.isCancelled else {
                        return
                    }
                    isPresented = hovering
                }
            }
            .onDisappear {
                hoverTask?.cancel()
            }
    }
}

/// Explains the four threat levels with their colors.
struct LevelLegendTip: View {
    @State private var isPresented = false

    private let entries: [(level: GhostLevel, name: String, meaning: String)] = [
        (.quiet, "Quiet", "Inside its learned range — nothing to do."),
        (.watch, "Watch", "Elevated or trending up; the radar is paying attention."),
        (.hot, "Hot", "Crossed a threshold or forecast to — worth triaging now."),
        (.critical, "Critical", "Far out of bounds or breaching imminently.")
    ]

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(isPresented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .contentShape(Circle().inset(by: -4))
        .modifier(HoverPopoverTrigger(isPresented: $isPresented))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Threat Levels")
                    .font(.subheadline.weight(.semibold))
                ForEach(entries, id: \.name) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(RadarTheme.accent(for: entry.level))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .font(.caption.weight(.semibold))
                            Text(entry.meaning)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text("Action levels summarize measured resource use, persistence, and system pressure. Celsius values come from hardware sensors and are shown separately. A high resource reading does not automatically mean a process should be stopped.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        }
        .accessibilityLabel("Threat level legend")
    }
}

/// Host memory pressure as a compact circular gauge, tinted by severity.
/// Hovering or clicking reveals the full breakdown and what pressure does to scoring.
struct MemoryPressureBadge: View {
    let pressure: SystemMemoryPressure

    @State private var isPresented = false

    private var color: Color {
        RadarTheme.accent(for: pressure.level.ghostLevel)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Gauge(value: pressure.usedFraction) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int((pressure.usedFraction * 100).rounded()))")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(color.gradient)
                .scaleEffect(0.62)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("PRESSURE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                        .lineLimit(1)
                    Text(pressure.isKnown ? pressure.level.label : "—")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(pressure.level == .nominal ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
                        .contentTransition(.opacity)
                }
            }
            .frame(minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverPopoverTrigger(isPresented: $isPresented))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("System Memory Pressure")
                    .font(.subheadline.weight(.semibold))
                if pressure.isKnown {
                    breakdownRow("Used", "\(Int((pressure.usedFraction * 100).rounded()))% of \(RadarFormat.bytes(pressure.totalBytes))")
                    breakdownRow("Available", RadarFormat.bytes(pressure.availableBytes))
                    breakdownRow("Compressed", RadarFormat.bytes(pressure.compressedBytes))
                    Divider()
                }
                Text("Sampled from host VM statistics every refresh. At Warning or Critical, large families get boosted scores — the same footprint matters more when the whole machine is starved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 270, alignment: .leading)
        }
        .accessibilityLabel("System memory pressure \(pressure.level.label), \(pressure.summaryText)")
    }

    private func breakdownRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }
}
