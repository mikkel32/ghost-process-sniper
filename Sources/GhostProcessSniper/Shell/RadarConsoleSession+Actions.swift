import AppKit
import Darwin
import GhostProcessSniperCore

/// Actions shared by the feature screens: stopping anything search finds,
/// undoing snoozes and ignores, and copying or revealing a process.
extension RadarConsoleSession {
    var browserRows: [ProcessBrowserRowModel] {
        queries.snapshot.browserRows
    }

    /// Stops any live process, tracked or not, through the usual preview.
    func prepareKill(processIdentity identity: ProcessIdentity, name: String) {
        guard let family = ProcessFamily.adHoc(rootedAt: identity, in: monitor.sampledProcesses, currentUserID: geteuid()) else {
            showToast("\(name) already exited", systemImage: "checkmark.circle")
            return
        }
        prepareKill(family)
    }

    /// Stops the supervisor that would otherwise restart what it watches.
    func prepareKill(supervisor: KillSupervisor) {
        guard let pid = supervisor.pid,
              let process = monitor.sampledProcesses.first(where: { $0.pid == pid }) else {
            showToast("\(supervisor.name) already exited", systemImage: "checkmark.circle")
            return
        }
        prepareKill(processIdentity: process.identity, name: supervisor.name)
    }

    /// Removes the user's snooze or ignore rules for a family (Unsnooze,
    /// Stop Ignoring), then rescans so the page shows it as watched again.
    func unmute(signatureID: String, name: String) {
        let rules = monitor.rules.filter {
            !$0.isBuiltIn && $0.match.signatureID == signatureID && ($0.action == .snooze || $0.action == .ignore)
        }
        guard !rules.isEmpty else { return }
        let wasIgnored = rules.contains { $0.action == .ignore }
        Task {
            for rule in rules { await monitor.deleteRule(id: rule.id) }
            refresh()
        }
        showToast(wasIgnored ? "Watching \(name) again" : "Unsnoozed \(name)", systemImage: "bell")
    }

    /// Deletes a rule and offers Undo, which saves the same rule again.
    func removeRule(_ rule: RadarRule, message: String) {
        Task { await monitor.deleteRule(id: rule.id) }
        let monitor = monitor
        showToast(message, systemImage: "trash", action: RadarToast.Action(title: "Undo") {
            Task { await monitor.save(rule: rule) }
        })
    }

    func copyToPasteboard(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(toast, systemImage: "doc.on.clipboard")
    }

    func revealInFinder(executablePath: String) {
        guard let path = FinderReveal.path(forExecutable: executablePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // Family menus resolve the family when clicked, so building a menu costs nothing.

    func copyRootPID(familyKey: String) {
        guard let family = monitor.family(signatureID: familyKey) else { return familyGone() }
        copyPIDs([family.root.pid])
    }

    func copyPIDs(_ pids: [Int32]) {
        let text = pids.map { String($0) }.joined(separator: " ")
        copyToPasteboard(text, toast: pids.count == 1 ? "Copied PID \(text)" : "Copied \(pids.count) PIDs")
    }

    func copyCommandLine(familyKey: String) {
        guard let family = monitor.family(signatureID: familyKey) else { return familyGone() }
        copyToPasteboard(family.root.commandLine, toast: "Copied command line")
    }

    func revealInFinder(familyKey: String) {
        guard let family = monitor.family(signatureID: familyKey) else { return familyGone() }
        revealInFinder(executablePath: family.root.executablePath)
    }

    private func familyGone() {
        showToast("That process is no longer running", systemImage: "checkmark.circle")
    }
}

extension RadarConsoleSession {
    /// After a stop that a supervisor undid, stops the supervisor itself:
    /// the parent of the process it started again.
    func prepareKillRespawner(of report: KillReport) {
        let sample = monitor.sampledProcesses
        guard let pid = report.respawnedPIDs.first,
              let child = sample.first(where: { $0.pid == pid }),
              let parent = sample.first(where: { $0.pid == child.parentPID }), parent.pid > 1 else {
            showToast("\(report.respawnedBy ?? "The supervisor") is no longer running", systemImage: "checkmark.circle")
            return
        }
        prepareKill(processIdentity: parent.identity, name: report.respawnedBy ?? parent.name)
    }
}

extension RadarConsoleSession {
    func snooze(families: [(key: String, name: String)], minutes: TimeInterval) {
        guard families.count > 1 else {
            if let family = families.first { snooze(familyKey: family.key, name: family.name, minutes: minutes) }
            return
        }
        let monitor = monitor
        Task {
            for family in families { await monitor.snooze(signatureID: family.key, minutes: minutes) }
        }
        showToast("Snoozed \(families.count) families for \(Self.durationText(minutes: minutes))", systemImage: "moon")
    }

    func ignore(families: [(key: String, name: String)]) {
        guard families.count > 1 else {
            if let family = families.first { ignore(familyKey: family.key, name: family.name) }
            return
        }
        let monitor = monitor
        Task {
            for family in families { await monitor.ignore(signatureID: family.key) }
        }
        showToast("Ignoring \(families.count) families \u{2014} undo under Rules", systemImage: "eye.slash")
    }
}
