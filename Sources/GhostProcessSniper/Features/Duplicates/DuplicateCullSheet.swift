import GhostProcessSniperCore
import SwiftUI
import ThinkingOrbsKit

/// "Stop the extras" as a checklist. Confirming checks every copy in a stop
/// preview of its own and stops the ones that pass, with live states.
struct DuplicateCullSheet: View {
    let run: DuplicateCullRun
    let start: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(run.copies) { copy in
                        DuplicateCullCopyRow(
                            copy: copy,
                            phase: run.phase,
                            showsDivider: copy.id != run.copies.last?.id,
                            run: run
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            footer
                .padding(16)
                .background(RadarTheme.panel)
        }
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled(run.isRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stop Extra \(run.clusterName) Copies")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(run.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Label("Each copy gets its own stop preview. Anything the preview flags is skipped and left running.",
                  systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch run.phase {
            case .choosing:
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(run.checkedCount) of \(run.copies.count) checked")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(role: .destructive, action: start) {
                    Label(DuplicateCullLabels.stopTitle(run.checkedCount), systemImage: "stop.circle")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(run.checkedCount == 0)
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text("Checking each copy\u{2019}s stop preview\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            case .stopping:
                // Each stop waits out a grace period of 2 s or more.
                ThinkingOrb(state: .breathing, size: .px20)
                    .accessibilityHidden(true)
                Text("Stopping \u{2014} each copy gets its grace period to exit\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            case .finished:
                Label(run.resultText, systemImage: run.stoppedCount > 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(run.stoppedCount > 0 ? Color.green : Color.orange)
                    .lineLimit(1)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minHeight: 24)
    }
}

private struct DuplicateCullCopyRow: View {
    let copy: DuplicateCullCopy
    let phase: DuplicateCullRun.Phase
    let showsDivider: Bool
    let run: DuplicateCullRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if phase == .choosing {
                    Toggle("Stop \(copy.name), PID \(String(copy.pid))", isOn: isChecked)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                } else {
                    statusIcon
                        .frame(width: 16)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(copy.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text("PID \(String(copy.pid))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(copy.isSkipped ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text(copy.memoryText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            if phase != .choosing, !copy.targets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(copy.targets, id: \.identity) { target in
                        KillTargetRow(target: target)
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
            }
        }
    }

    private var isChecked: Binding<Bool> {
        let id = copy.id
        let run = run
        return Binding(get: { run.copies.first { $0.id == id }?.isChecked ?? false },
                       set: { run.setChecked(id, $0) })
    }

    private var statusText: String {
        switch copy.status {
        case .waiting: phase == .choosing || copy.isChecked ? copy.reason : "Not checked \u{2014} left running"
        case .checking: "Checking its stop preview\u{2026}"
        case .skipped(let reason): "Skipped: \(reason)"
        case .stopping: "Stopping\u{2026}"
        case .finished(_, let summary): summary
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch copy.status {
        case .waiting:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .checking, .stopping:
            ProgressView()
                .controlSize(.mini)
        case .skipped:
            Image(systemName: "arrow.uturn.left.circle")
                .foregroundStyle(.orange)
        case .finished(let succeeded, _):
            Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(succeeded ? Color.green : Color.orange)
        }
    }
}
