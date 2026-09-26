import AppKit
import GhostProcessSniperCore
import SwiftUI

/// For a process launchd keeps alive: stop the service itself, by default
/// until the next login, optionally for good, with the commands to do or
/// undo it by hand.
struct KillLaunchdStopOptions: View {
    let job: LaunchdJob
    /// "Never force-stop" is on; it cannot hold back launchd's own SIGKILL.
    let forceHeld: Bool
    @Binding var stop: KillLaunchdStop

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("launchd keeps it running", systemImage: "arrow.clockwise")
                .font(.headline)
            Text("KeepAlive in \(job.plistName) starts it again within seconds of a normal stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Stop the launchd service (until next login)", isOn: stopsService)
            Toggle("Keep it off after restart", isOn: keepsOff)
                .disabled(stop == .none)
                .padding(.leading, 20)
            if forceHeld, stop != .none, let seconds = job.bootoutForceSeconds {
                Label("launchd force-stops it if it is still running \(RadarFormat.seconds(seconds)) after the service stops. Never force-stop holds back Ghost, not launchd.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            command("Keep it off yourself", job.keepStoppedCommand)
            command("Undo", job.undoCommand)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var stopsService: Binding<Bool> {
        Binding(get: { stop != .none }, set: { stop = $0 ? .untilLogin : .none })
    }

    private var keepsOff: Binding<Bool> {
        Binding(get: { stop == .keepOff }, set: { stop = $0 ? .keepOff : .untilLogin })
    }

    private func command(_ title: String, _ command: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .help(command)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Copy the command")
        }
    }
}
