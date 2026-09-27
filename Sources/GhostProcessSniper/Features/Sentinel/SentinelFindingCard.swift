import AppKit
import GhostProcessSniperCore
import SwiftUI

enum SentinelStyle {
    /// The `.app` for a path inside a bundle, so icons show the app rather
    /// than the generic executable inside it.
    static func iconPath(for path: String) -> String {
        guard let range = path.range(of: ".app/") else { return path }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func color(for severity: SentinelSeverity) -> Color {
        switch severity {
        case .info: .secondary
        case .notable: RadarTheme.brand
        case .suspicious: .orange
        case .dangerous: Color(nsColor: .systemRed)
        }
    }
}

/// One finding: what happened, the chain that led to it, the evidence, and
/// what to do. Nothing here acts without the usual stop preview.
struct SentinelFindingCard: View {
    let finding: SentinelFinding
    let actions: SentinelFindingActions

    @State private var showsFullCommand = false
    @State private var glowTrigger = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { SentinelStyle.color(for: finding.severity) }

    var body: some View {
        let glowColor = tint
        VStack(alignment: .leading, spacing: 12) {
            header
            SentinelLineageView(lineage: finding.lineage, tint: tint)
            signals
            commandBox
            provenance
            actionBar
        }
        .padding(16)
        .radarSurface(tint: tint, cornerRadius: 16)
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                .fill(tint.gradient)
                .frame(width: 4)
        }
        .opacity(finding.isRunning ? 1 : 0.78)
        // A dangerous finding announces itself once, then stays still.
        .keyframeAnimator(initialValue: 0.0, trigger: glowTrigger) { content, glow in
            content.shadow(color: glowColor.opacity(0.55 * glow), radius: 18 * glow)
        } keyframes: { _ in
            LinearKeyframe(1, duration: 0.35)
            LinearKeyframe(0.25, duration: 0.45)
            LinearKeyframe(0.9, duration: 0.35)
            LinearKeyframe(0, duration: 0.9)
        }
        .onAppear {
            if finding.severity == .dangerous, finding.isRunning, !reduceMotion { glowTrigger.toggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(finding.severity.label): \(finding.headline)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SentinelProgramIcon(path: finding.executablePath, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(finding.severity.label, systemImage: finding.severity.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.13), in: Capsule())
                    if !finding.isRunning {
                        Text("Exited")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    Text(finding.firstSeen, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(finding.headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.recommendation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("PID \(String(finding.identity.pid))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var signals: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(finding.signals.filter { $0.severity >= .notable || $0.kind == .downloadedExecutable }.enumerated()),
                    id: \.offset) { _, signal in
                SentinelSignalRow(signal: signal)
            }
        }
    }

    private var commandBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(finding.commandLine)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(showsFullCommand ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if finding.commandLine.count > 220 {
                Button(showsFullCommand ? "Show less" : "Show full command") {
                    withAnimation(RadarMotion.response(reduceMotion)) { showsFullCommand.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    @ViewBuilder private var provenance: some View {
        if !finding.connections.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("Connected to", systemImage: "network")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                WrappingHStack(spacing: 4) {
                    ForEach(finding.connections, id: \.self) { address in
                        Text(address)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.1), in: Capsule())
                    }
                }
            }
        }
        let signing = finding.signing
        if signing != nil || !finding.downloadedFrom.isEmpty {
            HStack(spacing: 14) {
                if let signing {
                    Label(signing.label, systemImage: signingIcon(signing.authority))
                        .foregroundStyle(signingColor(signing.authority))
                }
                if let source = finding.downloadedFrom.first {
                    Label(source, systemImage: "globe")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if finding.isRunning {
                Button {
                    actions.stop(finding)
                } label: {
                    Label("Stop…", systemImage: "stop.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(finding.severity >= .suspicious ? tint : RadarTheme.brand)
                .help("Opens the stop preview; nothing stops without your confirmation")
            }
            Button {
                actions.reveal(finding)
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(!FileManager.default.fileExists(atPath: finding.executablePath))
            Button {
                actions.copy(finding)
            } label: {
                Label("Copy Details", systemImage: "doc.on.doc")
            }
            if finding.isRunning {
                // Resolved on click: reading the family list here would redraw
                // this page on every scan instead of only when findings change.
                Button {
                    actions.openFamily(finding)
                } label: {
                    Label("Open Family", systemImage: "arrow.up.right.square")
                }
            }
            Spacer(minLength: 8)
            Menu {
                if let offer = finding.trustOffer {
                    Button(offer.title) { actions.trust(finding) }
                } else {
                    // An invalid signature, or one not read yet, cannot be trusted safely.
                    Button("Trust (checking its signature\u{2026})") {}
                        .disabled(true)
                }
                Button("Dismiss This Finding") { actions.dismiss(finding) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(finding.trustOffer.map { "Trust: \($0.scope). Dismiss hides only this finding." }
                  ?? "Dismiss hides only this finding")
        }
        .controlSize(.small)
    }

    private func signingIcon(_ authority: CodeSigningSummary.Authority) -> String {
        switch authority {
        case .apple, .appStore, .developerID: "checkmark.seal"
        case .otherCertificate, .adHoc: "signature"
        case .unsigned: "exclamationmark.shield"
        case .invalid: "xmark.seal"
        }
    }

    private func signingColor(_ authority: CodeSigningSummary.Authority) -> Color {
        switch authority {
        case .apple, .appStore, .developerID: .green
        case .otherCertificate, .adHoc: .secondary
        case .unsigned: .orange
        case .invalid: Color(nsColor: .systemRed)
        }
    }
}

struct SentinelSignalRow: View {
    let signal: SentinelSignal

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: signal.kind.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(SentinelStyle.color(for: signal.severity))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(signal.kind.title)
                    .font(.callout.weight(.semibold))
                Text(signal.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let evidence = signal.evidence, !evidence.isEmpty {
                    Text(evidence)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(SentinelStyle.color(for: signal.severity).opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }
}

/// "Google Chrome › zsh › curl", with app icons for app steps.
struct SentinelLineageView: View {
    let lineage: [SentinelLineageNode]
    let tint: Color

    var body: some View {
        WrappingHStack(spacing: 4) {
            ForEach(Array(lineage.enumerated()), id: \.offset) { index, node in
                HStack(spacing: 4) {
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    let isLast = index == lineage.count - 1
                    HStack(spacing: 5) {
                        if node.executablePath.contains(".app/") {
                            SentinelProgramIcon(path: node.executablePath, size: 15)
                        } else {
                            Image(systemName: "terminal")
                                .font(.caption2)
                                .foregroundStyle(isLast ? tint : .secondary)
                        }
                        Text(node.displayName)
                            .font(.caption.weight(isLast ? .bold : .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((isLast ? tint : Color.primary).opacity(isLast ? 0.14 : 0.06), in: Capsule())
                    .help("PID \(String(node.pid)) · \(node.executablePath)")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Launched by " + lineage.map(\.displayName).joined(separator: ", then "))
    }
}

/// What a finding's buttons do, supplied by the page.
struct SentinelFindingActions {
    let stop: (SentinelFinding) -> Void
    let reveal: (SentinelFinding) -> Void
    let copy: (SentinelFinding) -> Void
    let trust: (SentinelFinding) -> Void
    let dismiss: (SentinelFinding) -> Void
    let openFamily: (SentinelFinding) -> Void
}

/// An app's own icon, or a terminal glyph for command-line programs, whose
/// file icon is a generic "exec" document.
struct SentinelProgramIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        if path.contains(".app") {
            ThermalAppIcon(path: SentinelStyle.iconPath(for: path), isSystemProcess: false, size: size)
        } else {
            Image(systemName: "terminal.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}
