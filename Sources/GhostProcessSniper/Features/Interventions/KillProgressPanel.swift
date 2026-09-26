import GhostProcessSniperCore
import SwiftUI
import ThinkingOrbsKit

/// A stop in progress: what is happening in plain words, a countdown for a
/// clean-exit wait long enough to read, each process as it goes, and the
/// two ways to cut it short.
struct KillProgressPanel: View {
    let progress: KillLiveProgress
    /// The processes this run acts on, before their live states.
    let targets: [KillTarget]
    /// Processes the preview left out: not yours, or already gone.
    let skippedCount: Int
    let forceHeld: Bool
    let waitingStopped: Bool
    let holdForce: () -> Void
    let stopWaiting: () -> Void

    /// Set half a second into a long wait, so a fast exit never flashes it.
    @State private var orbVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                status
                if progress.wait?.showsIndicator != true {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                controls
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("Processes")
                    .font(.headline)
                KillTargetRows(rows: progress.rows(for: targets))
                if skippedCount > 0 {
                    Text("\(skippedCount) skipped (not yours or already gone)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !progress.recentEvents.isEmpty {
                recentSteps
            }
        }
        .task(id: progress.wait?.deadline) {
            orbVisible = false
            guard progress.wait?.showsIndicator == true else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            withAnimation(.easeIn(duration: 0.25)) { orbVisible = true }
        }
        // Once per stage: a force stage retitles itself for every process.
        .onChange(of: progress.stage) { _, _ in
            AccessibilityNotification.Announcement(progress.headline).post()
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            if let wait = progress.wait, wait.showsIndicator {
                if orbVisible {
                    ThinkingOrb(state: .breathing, size: .px20, speed: 0.7)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                Text(progress.headline)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("up to")
                    Text(timerInterval: wait.startedAt...wait.deadline, countsDown: true)
                        .monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else {
                Text(progress.headline)
                    .font(.callout.weight(.medium))
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: progress.headline)
    }

    @ViewBuilder
    private var controls: some View {
        let waiting = progress.wait?.showsIndicator == true && !waitingStopped
        if waiting || !forceHeld {
            HStack(spacing: 8) {
                if waiting {
                    Button(action: stopWaiting) {
                        Label("Stop Waiting", systemImage: "forward.end")
                    }
                    .help("End the wait now and report what is still running. Nothing is force-stopped.")
                }
                if !forceHeld {
                    Button(action: holdForce) {
                        Label("Skip Force", systemImage: "hand.raised")
                    }
                    .help("Let the polite steps finish, then report anything still running instead of force-stopping it.")
                }
            }
            .controlSize(.small)
        }
    }

    private var recentSteps: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Recent steps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(progress.recentEvents) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(KillLiveProgress.phaseText(for: event.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Text(event.message)
                        .lineLimit(1)
                        .help(event.message)
                }
            }
        }
        .font(.caption2.monospacedDigit())
    }
}
