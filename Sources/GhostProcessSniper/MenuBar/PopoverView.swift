import AppKit
import GhostProcessSniperCore
import SwiftUI

struct PopoverView: View {
    let monitor: ProcessMonitor

    let notifier: UserNotificationRadarNotifier
    let onOpenConsole: () -> Void
    let onOpenFamily: (String) -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(spacing: 12) {
                Label("CPU \(monitor.thermals.temperatureText(monitor.thermals.cpuCelsius))", systemImage: "cpu")
                Spacer(minLength: 0)
                Label("GPU \(monitor.thermals.temperatureText(monitor.thermals.gpuCelsius))", systemImage: "thermometer.medium")
            }
            .font(.callout.monospacedDigit().weight(.medium))
            .padding(10)
            .radarSurface(tint: RadarTheme.brand, cornerRadius: 10)
            summary
            topFamilies
            popoverHealth
            actions
        }
        .padding(14)
        .frame(width: 380)
        .tint(RadarTheme.brand)
        .background {
            LinearGradient(
                colors: [RadarTheme.accent(for: monitor.statusLevel).opacity(0.09), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
        .task {
            await monitor.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RadarBrandMark(level: monitor.statusLevel, size: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("LIVE SYSTEM RADAR")
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(RadarTheme.accent(for: monitor.statusLevel))
                Text("Ghost Process Sniper")
                    .font(.headline.weight(.bold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                guard !isRefreshing else {
                    return
                }
                isRefreshing = true
                Task {
                    let started = Date()
                    await monitor.refresh()
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed < 0.7 {
                        try? await Task.sleep(nanoseconds: UInt64((0.7 - elapsed) * 1_000_000_000))
                    }
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, isActive: isRefreshing)
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "Scanning processes" : "Scan now")
            .help("Refresh")
            .keyboardShortcut("r")
        }
        .padding(.bottom, 2)
    }

    private var summary: some View {
        HStack(spacing: 8) {
            RadarChip(title: "State", value: MenuBarStatusPresentation(state: monitor.publishedState).compactStateText, systemImage: RadarStyle.icon(for: monitor.summary.level), level: monitor.summary.level)
            RadarChip(title: "Hot", value: "\(monitor.summary.hotCount)", systemImage: "flame", level: monitor.summary.hotCount > 0 ? .hot : .quiet)
            RadarChip(title: "Memory", value: RadarFormat.bytes(monitor.summary.totalMemoryBytes), systemImage: "memorychip", level: .watch)
        }
        .padding(5)
        .radarSurface(tint: RadarTheme.accent(for: monitor.summary.level), cornerRadius: 14)
    }

    private var topFamilies: some View {
        RadarSection(title: "Top Radar", subtitle: "\(monitor.summary.familyCount) watched") {
            VStack(spacing: 8) {
                let items = monitor.consoleSnapshot.compact.topRiskRows

                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(.green.gradient)
                        Text("All Quiet")
                            .font(.subheadline.weight(.semibold))
                        Text(monitor.storeError ?? "\(monitor.engineStatus.processText) processes sampled, nothing misbehaving")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92)
                } else {
                    ForEach(items.prefix(3)) { item in
                        Button {
                            onOpenFamily(item.id)
                        } label: {
                            CompactPopoverFamilyRow(row: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                onOpenFamily(item.id)
                            } label: {
                                Label("Show in Console", systemImage: "rectangle.3.group")
                            }
                            Menu {
                                FamilySnoozeMenu { minutes in
                                    Task { await monitor.snooze(signatureID: item.id, minutes: minutes) }
                                }
                            } label: {
                                Label("Snooze", systemImage: "moon")
                            }
                            Button {
                                Task { await monitor.ignore(signatureID: item.id) }
                            } label: {
                                Label("Ignore Family", systemImage: "eye.slash")
                            }
                        }
                        if item.id != items.prefix(3).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var popoverHealth: some View {
        HStack(spacing: 8) {
            CompactRadarChip(title: "Refresh", value: monitor.engineStatus.refreshText, systemImage: "timer")
            CompactRadarChip(
                title: "Pressure",
                value: monitor.systemPressure.isKnown ? monitor.systemPressure.level.label : "—",
                systemImage: "gauge.with.needle",
                level: monitor.systemPressure.level.ghostLevel
            )
            CompactRadarChip(title: "Backlog", value: monitor.engineStatus.backlogText, systemImage: "externaldrive")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .radarSurface(tint: RadarTheme.brand, cornerRadius: 12)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                onOpenConsole()
            } label: {
                Label("Open Dashboard", systemImage: "rectangle.3.group")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("o")

            Spacer()

            Button {
                Task { _ = await notifier.requestAuthorization() }
            } label: {
                Image(systemName: "bell.badge")
            }
            .buttonStyle(.borderless)
            .help("Allow notifications")

            Button(action: onOpenSettings) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Menu {
                Button("Quit Ghost Process Sniper", action: onQuit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .help("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .radarSurface(tint: RadarTheme.brand, cornerRadius: 12)
    }

    private var headerSubtitle: String {
        if let error = monitor.storeError {
            return error
        }
        return MenuBarStatusPresentation.normalizedStatus(monitor.summary.statusText)
    }
}

private struct CompactPopoverFamilyRow: View {
    let row: CompactSidebarRowModel

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: row.systemImage)
                .foregroundStyle(RadarStyle.color(for: row.level))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ScoreCapsuleBadge(scoreText: row.statusText, level: row.level)
                }
                Text(row.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovering ? 1 : 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 5)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .help(row.helpText)
    }
}
