import AppKit
import Darwin
import GhostProcessSniperCore

/// Actions shared by the feature screens: stopping anything search finds,
/// undoing snoozes and ignores, and copying or revealing a process.
extension RadarConsoleSession {
    var browserRows: [ProcessBrowserRowModel] {
        queries.snapshot.browserRows
    }

    /// A `port:` search has every same-user process's listening ports read on
    /// the next refresh, so a quiet dev server's port is findable. It asks
    /// again only when the searched ports change, not on every keystroke.
    func requestPortCensusIfNeeded(for searchText: String) {
        let ports = Set(ProcessSearchQuery(searchText).ports.filter { !$0.isNegated }.flatMap(\.values))
        guard ports != censusPorts else { return }
        censusPorts = ports
        if !ports.isEmpty {
            monitor.requestPortCensus()
        }
    }

    /// Stops any live process, tracked or not, through the usual preview.
    func prepareKill(processIdentity identity: ProcessIdentity, name: String) {
        guard let family = ProcessFamily.adHoc(rootedAt: identity, in: monitor.sampledProcesses, currentUserID: geteuid()) else {
            showToast("\(name) already exited", systemImage: "checkmark.circle")
            return
        }
        prepareKill(family)
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
        let monitor = monitor
        Task { await monitor.deleteRule(id: rule.id) }
        showToast(message, systemImage: "trash", action: RadarToast.Action(title: "Undo") {
            Task { await monitor.save(rule: rule) }
        })
    }

    func copyReport() {
        Task {
            let report = await monitor.exportIncidentReport()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            showToast("Incident report copied", systemImage: "doc.on.clipboard")
        }
    }

    func copyDiagnostics() {
        Task {
            let report = await monitor.exportDiagnosticsReport()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            showToast("Diagnostics copied", systemImage: "stethoscope")
        }
    }

    func copyDuplicateReport(_ row: DuplicateClusterViewModel) {
        let detail = DuplicateClusterDetailModel(cluster: row.cluster)
        let report = [
            "Ghost Process Sniper Duplicate Cluster",
            "Name: \(detail.title)",
            "Key: \(detail.keyText)",
            "Reason: \(detail.captureReason)",
            "Kind: \(row.kindText)",
            "Instances: \(row.countText), independent roots: \(row.rootCountText)",
            "Memory: \(row.memoryText), CPU: \(row.cpuText)",
            "PIDs: \(row.pidText)",
            "Commands:",
            detail.commandHints.isEmpty ? "  none" : detail.commandHints.map { "  \($0)" }.joined(separator: "\n"),
            "Paths:",
            detail.pathHints.isEmpty ? "  none" : detail.pathHints.map { "  \($0)" }.joined(separator: "\n"),
            "Related families:",
            detail.relatedFamilyKeys.isEmpty ? "  none" : detail.relatedFamilyKeys.map { "  \($0)" }.joined(separator: "\n")
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        showToast("Duplicate report copied", systemImage: "doc.on.clipboard")
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

    /// After a stop that a supervisor undid, stops the supervisor itself:
    /// the parent of the process it started again.
    func prepareKillRespawner(of report: KillReport) {
        let sample = monitor.sampledProcesses
        guard let pid = report.respawnedPIDs.first,
              let child = sample.first(where: { $0.pid == pid }) else {
            showToast("\(report.respawnedBy ?? "The supervisor") is no longer running", systemImage: "checkmark.circle")
            return
        }
        // A launchd job restarted it: there is no parent process to stop.
        // A fresh stop of the restarted process offers booting out the job.
        guard child.parentPID > 1 else {
            prepareKill(processIdentity: child.identity, name: child.name)
            return
        }
        guard let parent = sample.first(where: { $0.pid == child.parentPID }) else {
            showToast("\(report.respawnedBy ?? "The supervisor") is no longer running", systemImage: "checkmark.circle")
            return
        }
        prepareKill(processIdentity: parent.identity, name: report.respawnedBy ?? parent.name)
    }

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
