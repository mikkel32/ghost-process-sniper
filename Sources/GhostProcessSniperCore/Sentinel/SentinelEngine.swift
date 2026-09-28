import Foundation

/// Watches every process for signs of an attack and keeps the launch feed.
///
/// Each identity is judged once, when it first appears (or again when its
/// arguments arrive a tick late), with the chain of processes that launched
/// it captured at that moment, because a parent that exits takes that
/// evidence with it. The spawn watcher adds processes that start and finish
/// between scans. Signatures, download marks and the privacy sensors are
/// read off the refresh path and folded in when they arrive.
public actor SentinelEngine {
    /// What the engine may touch. Tests run the rules without live reads.
    public struct Live: Sendable {
        public var watchesSpawns: Bool
        public var readsSensors: Bool
        public var inspectsSignatures: Bool
        public var watchesStartupItems: Bool

        public init(watchesSpawns: Bool = true, readsSensors: Bool = true, inspectsSignatures: Bool = true,
                    watchesStartupItems: Bool = true) {
            self.watchesSpawns = watchesSpawns
            self.readsSensors = readsSensors
            self.inspectsSignatures = inspectsSignatures
            self.watchesStartupItems = watchesStartupItems
        }

        public static let full = Live()
        public static let rulesOnly = Live(watchesSpawns: false, readsSensors: false, inspectsSignatures: false,
                                           watchesStartupItems: false)
    }

    private struct Record {
        let subject: SentinelSubject
        /// Kept so the rules can run again once the signature is known.
        let ancestors: [SentinelSubject]
        let lineage: [SentinelLineageNode]
        var evaluation: SentinelEvaluation
        let firstSeen: Date
        var provenanceApplied = false
        var provenance: ExecutableProvenance?
        var signing: CodeSigningSummary?
        var downloadedFrom: [String] = []
        /// Evidence from outside the rules: the signature, the download mark, the microphone.
        var extraSignals: [SentinelSignal] = []
        /// The pipeline this stdin runner belongs to, once its siblings were seen.
        var pipeline: PipelineCorrelator.Pipeline?
    }

    static let feedCapacity = 300
    static let findingRetention: TimeInterval = 30 * 60
    static let exitedRecordRetention: TimeInterval = 120

    private let live: Live
    /// Ghost never judges itself or what it starts: run from its disk image
    /// or a development build folder, it would otherwise flag its own location.
    private let ownPID: Int32
    private let watcher: SpawnWatcher?
    private let inspector: CodeSignatureInspector?
    private let persistence: PersistenceMonitor?
    private let sensorMonitor: PrivacySensorMonitor?
    /// Records still waiting for a signature check; empty once caught up.
    private var pendingProvenance: Set<ProcessIdentity> = []
    private var launchItems: [LaunchItem] = []
    private var persistenceGeneration: UInt64 = .max
    private var records: [ProcessIdentity: Record] = [:]
    private var findings: [ProcessIdentity: SentinelFinding] = [:]
    /// Who was running at the last scan.
    private var alive: Set<ProcessIdentity> = []
    private var launches: [LaunchEvent] = []
    private var launchTimes: [Date] = []
    private var dismissed: Set<String> = []
    private var trust: SentinelTrust
    private let trustStore: SentinelTrustStore?
    /// Numbers feed entries: an exec keeps its process's identity, so one
    /// process can appear twice with different commands.
    private var launchSequence: UInt64 = 0
    private var pipelines = PipelineCorrelator()
    private var sensors = PrivacySensorState.unknown
    private var watchedAppNames: [String] = []
    private var ticks: UInt64 = 0
    private var revision: UInt64 = 0
    private var report = SentinelReport.empty
    private var lastConnectionRead: Date?

    public init(live: Live = .full, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                trustStore: SentinelTrustStore? = nil, onUrgentSpawn: @escaping @Sendable () -> Void = {}) {
        self.live = live
        self.ownPID = ownPID
        self.trustStore = trustStore
        trust = SentinelTrust(trustStore?.load() ?? [])
        watcher = live.watchesSpawns ? SpawnWatcher(onRunnerFromContentApp: onUrgentSpawn) : nil
        inspector = live.inspectsSignatures ? CodeSignatureInspector() : nil
        persistence = live.watchesStartupItems ? PersistenceMonitor(onNewItem: onUrgentSpawn) : nil
        persistence?.start()
        sensorMonitor = live.readsSensors ? PrivacySensorMonitor(onChange: onUrgentSpawn) : nil
        sensorMonitor?.start()
    }

    // MARK: - User decisions

    /// Hides one finding; the same program starting again is judged afresh.
    public func dismiss(findingID: String) {
        dismissed.insert(findingID)
        revision &+= 1
        report = buildReport(now: Date())
    }

    /// Trusts what the finding's Trust item offers: the program's signer,
    /// its exact build or file, or one script or command of a shell or tool.
    @discardableResult
    public func trust(findingID: String) -> SentinelTrustEntry? {
        guard let record = records.first(where: { SentinelFinding.key(for: $0.key) == findingID })?.value,
              let entry = SentinelTrust.offer(for: record.subject, provenance: record.provenance, now: Date(),
                                              commandText: record.pipeline?.text)
        else { return nil }
        trust.insert(entry)
        trustChanged(path: entry.path)
        return entry
    }

    public func revokeTrust(id: String) {
        guard let entry = trust.entries.first(where: { $0.id == id }), trust.remove(id: id) else { return }
        trustChanged(path: entry.path)
    }

    /// Saves, and judges every known process at the path again.
    private func trustChanged(path: String) {
        trustStore?.save(trust.entries)
        let now = Date()
        for (identity, record) in records where record.subject.executablePath == path {
            upsertFinding(for: identity, running: alive.contains(identity), now: now)
        }
        revision &+= 1
        report = buildReport(now: now)
    }

    public var currentReport: SentinelReport { report }

    // MARK: - Each refresh

    public func ingest(processes: [ProcessMetrics], uiVisible: Bool, now: Date) async -> SentinelReport {
        ticks &+= 1
        let isBaseline = ticks == 1
        var changed = false
        var byPID: [Int32: SentinelSubject] = [:]
        byPID.reserveCapacity(processes.count)
        for process in processes where byPID[process.pid] == nil {
            byPID[process.pid] = SentinelSubject(process)
        }
        let alive = Set(processes.map(\.identity))
        self.alive = alive
        let own = Self.family(of: ownPID, in: processes)

        // Spawns caught between scans come first, in the order they started.
        for capture in watcher?.drain() ?? [] where !own.contains(capture.identity.pid) && !own.contains(capture.parentPID) {
            let subject = SentinelSubject(
                identity: capture.identity, parentPID: capture.parentPID, userID: capture.userID,
                name: capture.name, executablePath: capture.executablePath, commandLine: capture.commandLine,
                isSystemProcess: SentinelCatalog.isSystemLocation(capture.executablePath),
                processGroupID: capture.processGroupID)
            if byPID[subject.identity.pid] == nil { byPID[subject.identity.pid] = subject }
            if let record = records[subject.identity], record.subject.commandLine == subject.commandLine { continue }
            let exited = !alive.contains(subject.identity)
            judge(subject, byPID: byPID, at: capture.at, source: .spawnWatch, feed: true, running: !exited, now: now)
            changed = true
        }

        for process in processes where !own.contains(process.pid) {
            let subject = byPID[process.pid] ?? SentinelSubject(process)
            guard subject.identity == process.identity else { continue }
            if let record = records[process.identity] {
                // Arguments can arrive a tick after the process, and listening
                // ports when its forensics are read; judge again with them.
                let longerCommand = record.subject.commandLine != process.commandLine
                    && process.commandLine.count > record.subject.commandLine.count
                let newPorts = !process.forensics.listeningPorts.isEmpty
                    && Set(process.forensics.listeningPorts) != Set(record.subject.listeningPorts)
                guard longerCommand || newPorts else { continue }
            }
            let isNew = records[process.identity] == nil
            judge(SentinelSubject(process), byPID: byPID, at: now, source: .scan, feed: isNew && !isBaseline,
                  running: true, now: now)
            changed = true
        }

        changed = refreshLiveness(alive: alive, now: now) || changed
        changed = await applyProvenance(alive: alive, now: now) || changed
        if let sensorMonitor {
            // Listener-driven: a real read happens only after a device change.
            let read = sensorMonitor.current(names: { pid in byPID[pid].map(\.name) }, now: now)
            if read != sensors {
                sensors = read
                changed = true
                changed = flagRecorders(byPID: byPID, skipping: own, now: now) || changed
            }
        }
        changed = updateWatchedApps(processes) || changed
        changed = readConnections(uiVisible: uiVisible, now: now) || changed
        changed = await refreshLaunchItems() || changed

        let minuteAgo = now.addingTimeInterval(-60)
        let launchCount = launchTimes.count
        launchTimes.removeAll { $0 < minuteAgo }
        changed = changed || launchTimes.count != launchCount
        if changed {
            revision &+= 1
            report = buildReport(now: now)
        }
        return report
    }

    // MARK: - Judging

    private func judge(_ subject: SentinelSubject, byPID: [Int32: SentinelSubject], at: Date, source: LaunchEventSource,
                       feed: Bool, running: Bool, now: Date) {
        let previous = records[subject.identity]
        // Judged again (late arguments, new ports): a parent that has exited since is gone from this
        // scan, and launchd has adopted the process. The chain seen first is what launched it.
        let fresh = Self.ancestors(of: subject, in: byPID)
        let kept = previous?.ancestors ?? []
        let ancestors = kept.count > fresh.count ? kept : fresh
        let lineage = (ancestors.reversed() + [subject]).map {
            SentinelLineageNode(pid: $0.identity.pid, name: $0.name, executablePath: $0.executablePath)
        }
        // What is known about the same file still holds; an exec into another program starts over.
        let known = previous.flatMap { $0.subject.executablePath == subject.executablePath ? $0 : nil }
        let evaluation = SentinelRules.evaluate(subject, ancestors: ancestors, signing: known?.signing, pipeline: previous?.pipeline)
        // System binaries are Apple's; only third-party programs get a signature check.
        let needsProvenance = !subject.isSystemLocation && subject.executablePath.hasPrefix("/")
            && known?.provenanceApplied != true
        records[subject.identity] = Record(
            subject: subject, ancestors: ancestors, lineage: lineage, evaluation: evaluation,
            firstSeen: previous?.firstSeen ?? at, provenanceApplied: !needsProvenance, provenance: known?.provenance,
            signing: known?.signing,
            downloadedFrom: known?.downloadedFrom ?? [], extraSignals: known?.extraSignals ?? [], pipeline: previous?.pipeline)
        if needsProvenance { pendingProvenance.insert(subject.identity) }
        for pipeline in pipelines.observe(subject, now: now) {
            correlate(pipeline, running: pipeline.runner == subject.identity ? running : nil, now: now)
        }

        if feed, Self.belongsInFeed(subject, parent: ancestors.first, severity: evaluation.severity),
           !launches.contains(where: { $0.identity == subject.identity && $0.commandLine == subject.commandLine }) {
            launchSequence &+= 1
            launches.append(LaunchEvent(
                at: at, identity: subject.identity, name: subject.name, executablePath: subject.executablePath,
                commandLine: String(subject.commandLine.prefix(2_048)), lineage: lineage, severity: evaluation.severity,
                signalKinds: evaluation.signals.filter { $0.severity >= .notable }.map(\.kind),
                source: source, isSystem: subject.isSystemLocation,
                exitedAfter: running ? nil : max(0, now.timeIntervalSince(at)), sequence: launchSequence))
            if launches.count > Self.feedCapacity { launches.removeFirst(launches.count - Self.feedCapacity) }
            launchTimes.append(at)
        }
        upsertFinding(for: subject.identity, running: running, now: now)
    }

    /// A stdin runner turned out to be the end of `curl … | sh`: judged again
    /// as the whole pipeline, whichever member arrived last.
    private func correlate(_ pipeline: PipelineCorrelator.Pipeline, running: Bool?, now: Date) {
        guard var record = records[pipeline.runner], record.pipeline != pipeline else { return }
        record.pipeline = pipeline
        record.evaluation = SentinelRules.evaluate(record.subject, ancestors: record.ancestors, signing: record.signing,
                                                   pipeline: pipeline)
        records[pipeline.runner] = record
        upsertFinding(for: pipeline.runner, running: running ?? alive.contains(pipeline.runner), now: now)
    }

    /// Rebuilds a finding from the record: the rules' verdict plus the
    /// evidence gathered since (signature, download mark, microphone).
    private func upsertFinding(for identity: ProcessIdentity, running: Bool, now: Date) {
        guard let record = records[identity] else { return }
        var trustSignals: [SentinelSignal] = []
        switch trust.match(record.subject, provenance: record.provenance, commandText: record.pipeline?.text) {
        case .trusted, .pending:
            // A trusted program waits for its signature rather than flash an alarm.
            findings[identity] = nil
            return
        case .changed(let entry):
            trustSignals.append(SentinelSignal(.trustedProgramChanged, .suspicious,
                "You trusted \(entry.name) \(entry.trustedAs); \(SentinelTrust.describe(record.provenance)).",
                evidence: record.provenance?.signing.label))
        case .none:
            break
        }
        let previous = findings[identity]
        var signals = record.evaluation.signals
        signals += (record.extraSignals + trustSignals).filter { !signals.contains($0) }
        signals.sort { $0.severity > $1.severity }
        guard (signals.map(\.severity).max() ?? .info) >= .notable else {
            findings[identity] = nil
            return
        }
        var finding = SentinelFinding(
            identity: identity, name: record.subject.name, executablePath: record.subject.executablePath,
            commandLine: String(record.subject.commandLine.prefix(4_096)), lineage: record.lineage, signals: signals,
            headline: SentinelRules.headline(for: record.subject, signals: signals,
                                              contentAncestor: record.evaluation.contentAncestor,
                                              fromTerminal: record.evaluation.fromTerminal),
            recommendation: SentinelRules.recommendation(for: signals, fromTerminal: record.evaluation.fromTerminal),
            firstSeen: previous?.firstSeen ?? record.firstSeen, lastSeen: now, isRunning: running,
            signing: record.signing, downloadedFrom: record.downloadedFrom)
        finding.connections = previous?.connections ?? []
        // Offered again at every judgement: once the signature arrives the offer can name the signer.
        finding.trustOffer = SentinelTrust.offer(for: record.subject, provenance: record.provenance, now: now,
                                                 commandText: record.pipeline?.text)
        findings[identity] = finding
    }

    private func refreshLiveness(alive: Set<ProcessIdentity>, now: Date) -> Bool {
        var changed = false
        for (identity, finding) in findings {
            let running = alive.contains(identity)
            if finding.isRunning != running {
                var updated = finding
                updated.isRunning = running
                if running { updated.lastSeen = now }
                findings[identity] = updated
                changed = true
            } else if running {
                findings[identity]?.lastSeen = now
            }
        }
        let before = findings.count
        findings = findings.filter { $0.value.isRunning || now.timeIntervalSince($0.value.lastSeen) < Self.findingRetention }
        // A dismissal lives as long as its finding, so the count stays true.
        let dismissedBefore = dismissed.count
        dismissed.formIntersection(findings.values.map(\.id))
        changed = changed || dismissed.count != dismissedBefore
        for (identity, record) in records
        where !alive.contains(identity) && now.timeIntervalSince(record.firstSeen) >= Self.exitedRecordRetention {
            records[identity] = nil
        }
        pipelines.prune(now: now)
        return changed || findings.count != before
    }

    // MARK: - Signatures and downloads

    private func applyProvenance(alive: Set<ProcessIdentity>, now: Date) async -> Bool {
        guard let inspector else { return false }
        pendingProvenance = pendingProvenance.filter { records[$0]?.provenanceApplied == false }
        guard !pendingProvenance.isEmpty else { return false }
        // Every non-system program is checked once; findings first.
        var wanted: [String] = []
        var seenPaths = Set<String>()
        let ordered = pendingProvenance.sorted { lhs, rhs in
            (findings[lhs] != nil ? 1 : 0) > (findings[rhs] != nil ? 1 : 0)
        }
        for identity in ordered {
            guard let path = records[identity]?.subject.executablePath, seenPaths.insert(path).inserted else { continue }
            wanted.append(path)
        }
        await inspector.request(wanted)
        let known = await inspector.snapshot(for: wanted)
        var changed = false
        let provenanceKinds: Set<SentinelSignalKind> = [.unsigned, .adHocSigned, .invalidSignature, .downloadedExecutable]
        for identity in pendingProvenance {
            guard var record = records[identity], let provenance = known[record.subject.executablePath] else { continue }
            let before = record.evaluation.severity
            record.provenanceApplied = true
            record.provenance = provenance
            record.signing = provenance.signing
            if trust.bindEarlierVersion(path: record.subject.executablePath, provenance: provenance, now: now) {
                trustStore?.save(trust.entries)
            }
            record.downloadedFrom = provenance.downloadedFrom
            // Rules that weigh the signer (a shared folder, a listener) run again now that it is known.
            record.evaluation = SentinelRules.evaluate(record.subject, ancestors: record.ancestors, signing: provenance.signing,
                                                       pipeline: record.pipeline)
            let oddly = record.evaluation.signals.contains {
                [.temporaryLocation, .hiddenLocation, .deletedExecutable, .downloadedExecutable].contains($0.kind) && $0.severity >= .notable
            }
            let extra = provenance.signals(for: record.subject, locatedOddly: oddly)
            record.extraSignals = record.extraSignals.filter { !provenanceKinds.contains($0.kind) } + extra
            records[identity] = record
            let meaningful = extra.contains { $0.severity >= .notable } || record.evaluation.severity != before
            // A trusted program's finding was held for this signature.
            guard meaningful || findings[identity] != nil || trust.hasEntries(for: record.subject.executablePath) else { continue }
            upsertFinding(for: identity, running: alive.contains(identity), now: now)
            changed = true
        }
        return changed
    }

    // MARK: - Connections

    /// Who each running finding is talking to; a handful of processes at most.
    private func readConnections(uiVisible: Bool, now: Date) -> Bool {
        guard live.inspectsSignatures,
              lastConnectionRead.map({ now.timeIntervalSince($0) >= (uiVisible ? 10 : 30) }) ?? true else { return false }
        lastConnectionRead = now
        var changed = false
        for (identity, finding) in findings where finding.isRunning {
            let connections = RemoteConnectionReader.connections(pid: identity.pid)
            if connections != finding.connections {
                findings[identity]?.connections = connections
                changed = true
            }
        }
        return changed
    }

    // MARK: - Startup items

    /// Re-reads startup items when their folders changed, and folds in each
    /// target program's signature once the inspector has it.
    private func refreshLaunchItems() async -> Bool {
        guard let persistence else { return false }
        var changed = false
        let snapshot = persistence.snapshot()
        if snapshot.generation != persistenceGeneration {
            persistenceGeneration = snapshot.generation
            launchItems = snapshot.items
            changed = true
        }
        guard let inspector else { return changed }
        let unsigned = launchItems.filter { $0.signing == nil && $0.programPath.hasPrefix("/")
            && !SentinelCatalog.isSystemLocation($0.programPath) && FileManager.default.fileExists(atPath: $0.programPath) }
        guard !unsigned.isEmpty else { return changed }
        let paths = unsigned.map(\.programPath)
        await inspector.request(paths)
        let known = await inspector.snapshot(for: paths)
        for index in launchItems.indices {
            guard launchItems[index].signing == nil, let provenance = known[launchItems[index].programPath] else { continue }
            let item = launchItems[index]
            // Judged again with the signer known, as a process is.
            let judged = PersistenceMonitor.judge(item, signing: provenance.signing)
            let oddly = judged.contains { [.temporaryLocation, .hiddenLocation].contains($0.kind) && $0.severity >= .notable }
            let subject = SentinelSubject(
                identity: ProcessIdentity(pid: 0, startTimeSeconds: 0, startTimeMicroseconds: 0), parentPID: 1, userID: 0,
                name: item.label, executablePath: item.programPath, commandLine: item.commandLine, isSystemProcess: false)
            let extra = provenance.signals(for: subject, locatedOddly: oddly || item.isNew)
                .filter { $0.kind != .downloadedExecutable || item.isNew }
            launchItems[index].signals = judged + extra.filter { signal in !judged.contains { $0.kind == signal.kind } }
            launchItems[index].signing = provenance.signing
            changed = true
        }
        return changed
    }

    // MARK: - Sensors

    /// A shell, script or unknown program recording audio is a finding; a
    /// meeting app doing it is only shown in the sensor panel.
    private func flagRecorders(byPID: [Int32: SentinelSubject], skipping own: Set<Int32>, now: Date) -> Bool {
        var changed = false
        for user in sensors.microphoneUsers where !own.contains(user.pid) {
            guard let subject = byPID[user.pid], let record = records[subject.identity] else { continue }
            let questionable = subject.isCommandRunner || record.evaluation.severity >= .notable
                || findings[subject.identity] != nil
            guard questionable, !record.extraSignals.contains(where: { $0.kind == .microphoneInUse }) else { continue }
            records[subject.identity]?.extraSignals.append(SentinelSignal(.microphoneInUse, .suspicious,
                "\(subject.program) is recording from the microphone.", evidence: subject.executablePath))
            upsertFinding(for: subject.identity, running: true, now: now)
            changed = true
        }
        return changed
    }

    // MARK: - Spawn watching

    private func updateWatchedApps(_ processes: [ProcessMetrics]) -> Bool {
        guard let watcher else { return false }
        var roots: [Int32: SpawnWatcher.RootRole] = [:]
        var names = Set<String>()
        for process in processes where LaunchOrigin.isAppMainBinary(path: process.executablePath, name: process.name) {
            if SentinelCatalog.contentApp(path: process.executablePath, name: process.name) != nil {
                roots[process.pid] = .contentApp
            } else if SentinelCatalog.isTerminalApp(path: process.executablePath, name: process.name) {
                roots[process.pid] = .terminal
            } else {
                continue
            }
            names.insert(SentinelCatalog.appName(forPath: process.executablePath) ?? process.name)
        }
        watcher.setRoots(roots)
        let sorted = names.sorted()
        guard sorted != watchedAppNames else { return false }
        watchedAppNames = sorted
        return true
    }

    // MARK: - Helpers

    /// A process and everything below it. Ghost rarely has children, so the
    /// usual answer costs one pass.
    static func family(of root: Int32, in processes: [ProcessMetrics]) -> Set<Int32> {
        guard processes.contains(where: { $0.parentPID == root && $0.pid != root }) else { return [root] }
        var children: [Int32: [Int32]] = [:]
        for process in processes where process.pid != process.parentPID {
            children[process.parentPID, default: []].append(process.pid)
        }
        var family: Set<Int32> = [root]
        var pending = [root]
        while let pid = pending.popLast() {
            for child in children[pid] ?? [] where family.insert(child).inserted {
                pending.append(child)
            }
        }
        return family
    }

    /// Parent first, up to launchd (excluded).
    static func ancestors(of subject: SentinelSubject, in byPID: [Int32: SentinelSubject]) -> [SentinelSubject] {
        var chain: [SentinelSubject] = []
        var visited: Set<Int32> = [subject.identity.pid]
        var parentPID = subject.parentPID
        while parentPID > 1, chain.count < 12, let parent = byPID[parentPID], visited.insert(parentPID).inserted {
            chain.append(parent)
            parentPID = parent.parentPID
        }
        return chain
    }

    /// New programs and anything flagged; not an app's own helpers or the
    /// constant churn of system services.
    static func belongsInFeed(_ subject: SentinelSubject, parent: SentinelSubject?, severity: SentinelSeverity) -> Bool {
        if severity >= .notable { return true }
        if subject.isSystemLocation && !subject.isCommandRunner { return false }
        if let bundle = CodeSignatureInspector.bundleRoot(of: subject.executablePath),
           let parent, parent.executablePath.hasPrefix(bundle + "/") {
            return false
        }
        return true
    }

    private func buildReport(now: Date) -> SentinelReport {
        let visible = findings.values
            .filter { !dismissed.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.firstSeen > rhs.firstSeen
            }
        return SentinelReport(
            findings: visible,
            launches: launches.reversed(),
            launchItems: launchItems.sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                if lhs.isNew != rhs.isNew { return lhs.isNew }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            },
            sensors: sensors,
            watchedAppNames: watchedAppNames,
            launchesLastMinute: launchTimes.count,
            dismissedCount: dismissed.count,
            trusted: trust.entries,
            revision: revision
        )
    }
}
