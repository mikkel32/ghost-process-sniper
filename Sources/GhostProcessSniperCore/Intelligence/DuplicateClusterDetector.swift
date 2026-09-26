import Darwin
import Foundation

/// Buckets same-user processes that run the same workload, then counts how
/// many independently started copies each bucket holds.
public struct DuplicateClusterDetector: Sendable {
    private let classifier: DevProcessClassifier
    private let currentUserID: UInt32
    private let minimumClusterSize: Int

    public init(
        classifier: DevProcessClassifier = DevProcessClassifier(),
        currentUserID: UInt32 = UInt32(geteuid()),
        minimumClusterSize: Int = 2
    ) {
        self.classifier = classifier
        self.currentUserID = currentUserID
        self.minimumClusterSize = max(2, minimumClusterSize)
    }

    public func detect(
        processes: [ProcessMetrics],
        classifications: [Int32: DevClassification],
        byPID: [Int32: ProcessMetrics]? = nil,
        now: Date = Date(),
        candidateKey: ((ProcessMetrics) -> DuplicateClusterKey?)? = nil
    ) -> DuplicateClusterSet {
        let started = Date()
        let byPID = byPID ?? Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var buckets: [DuplicateClusterKey: [ProcessMetrics]] = [:]
        buckets.reserveCapacity(processes.count / 2)

        for process in processes {
            let key: DuplicateClusterKey?
            if let candidateKey {
                key = candidateKey(process)
            } else {
                key = self.candidateKey(
                    for: process,
                    tokens: WorkloadTokens(process),
                    classification: classifications[process.pid] ?? classifier.classification(for: process)
                )
            }
            guard let key else {
                continue
            }
            buckets[key, default: []].append(process)
        }

        var clusters: [DuplicateProcessCluster] = []
        clusters.reserveCapacity(buckets.count)
        for (key, members) in buckets where members.count >= minimumClusterSize {
            let bestClassification = members
                .map { classifications[$0.pid] ?? classifier.classification(for: $0) }
                .max { $0.groupingPriority < $1.groupingPriority }
                ?? DevClassification(kind: .cliTool, confidence: 0.2, reason: "matching executable")
            let copies = Self.copyRoots(of: members, byPID: byPID)
            clusters.append(
                DuplicateProcessCluster(
                    key: key,
                    displayName: key.displayName,
                    members: members,
                    independentRootCount: max(1, copies.count),
                    likelyKind: bestClassification.kind,
                    classificationReason: bestClassification.reason,
                    copyRootIdentities: copies.map(\.identity),
                    keepIdentity: copies.count >= 2 ? Self.preferredCopy(copies)?.identity : nil
                )
            )
        }

        let sorted = clusters.sorted(by: Self.sortClusters)
        // A worker pool is one copy; promoting its members would make every
        // helper a family candidate.
        return DuplicateClusterSet(
            clusters: sorted,
            promotedIdentities: Set(sorted.filter { $0.independentRootCount >= 2 }.flatMap { $0.members.map(\.identity) }),
            detectorMilliseconds: Date().timeIntervalSince(started) * 1_000
        )
    }

    /// The cluster key, or nil when the process is not a duplicate candidate.
    /// It depends only on static process facts, so callers may cache it.
    func candidateKey(for process: ProcessMetrics, tokens: WorkloadTokens, classification: DevClassification) -> DuplicateClusterKey? {
        shouldConsider(process, tokens: tokens, classification: classification) ? key(for: process, tokens: tokens) : nil
    }

    /// One copy per independent start. A copy is the topmost member of a
    /// chain of matching processes. Copies started by launchd or a shell are
    /// independent; siblings under any other process are one tool's pool.
    static func copyRoots(of members: [ProcessMetrics], byPID: [Int32: ProcessMetrics]) -> [ProcessMetrics] {
        let memberPIDs = Set(members.map(\.pid))
        var independent: [ProcessMetrics] = []
        var pools: [Int32: ProcessMetrics] = [:]
        for member in members where !memberPIDs.contains(member.parentPID) {
            guard let launcher = byPID[member.parentPID], member.parentPID > 1, !isShell(launcher) else {
                independent.append(member)
                continue
            }
            if let existing = pools[launcher.pid], isOlder(existing, than: member) {
                continue
            }
            pools[launcher.pid] = member
        }
        return (independent + pools.values).sorted { $0.pid < $1.pid }
    }

    /// Newest start wins: the older copies are the ones left behind.
    static func preferredCopy(_ copies: [ProcessMetrics]) -> ProcessMetrics? {
        copies.max { isOlder($0, than: $1) }
    }

    private static func isOlder(_ lhs: ProcessMetrics, than rhs: ProcessMetrics) -> Bool {
        (lhs.identity.startTimeSeconds, lhs.identity.startTimeMicroseconds, lhs.pid) <
            (rhs.identity.startTimeSeconds, rhs.identity.startTimeMicroseconds, rhs.pid)
    }

    private static let shells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "xonsh", "tmux", "screen", "login", "sshd",
    ]

    private static func isShell(_ process: ProcessMetrics) -> Bool {
        let name = process.name.lowercased()
        return shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    private func shouldConsider(_ process: ProcessMetrics, tokens: WorkloadTokens, classification: DevClassification) -> Bool {
        guard process.userID == currentUserID, !process.isSystemProcess else {
            return false
        }
        // Apps launch once by design; their helpers and bundled CLI tools can
        // still pile up.
        if tokens.isAppMainBinary || isSystemPath(tokens.lowerPath) {
            return false
        }
        if classification.confidence >= 0.2 {
            return true
        }
        if process.executablePath.hasPrefix("/Users/") ||
            process.executablePath.hasPrefix("/opt/homebrew/") ||
            process.executablePath.hasPrefix("/usr/local/") {
            return true
        }
        return process.executablePath.isEmpty && !process.commandLine.isEmpty
    }

    private func isSystemPath(_ lowerPath: String) -> Bool {
        lowerPath.hasPrefix("/system/") || lowerPath.hasPrefix("/usr/libexec/") || lowerPath.hasPrefix("/library/apple/")
    }

    /// Executable path plus, for interpreters, the workload they run: node
    /// running vite and node running tsserver are not copies of each other.
    private func key(for process: ProcessMetrics, tokens: WorkloadTokens) -> DuplicateClusterKey? {
        let path = process.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !path.isEmpty {
            let binary = WorkloadTokens.basename(path).ifNotEmpty ?? process.name
            guard let workload = Self.workloadFingerprint(tokens) else {
                return DuplicateClusterKey(kind: .executablePath, value: path, displayName: binary)
            }
            let name = tokens.script.map { "\(binary) \($0)" } ?? binary
            return DuplicateClusterKey(kind: .executablePath, value: "\(path)|\(workload)", displayName: name)
        }
        let name = process.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else {
            return nil
        }
        let prefix = commandPrefix(process.commandLine)
        let value = prefix.isEmpty ? name : "\(name)|\(prefix)"
        return DuplicateClusterKey(kind: .commandPrefix, value: value, displayName: process.name)
    }

    /// The script, module or jar an interpreter runs, reduced to a stable
    /// word and anchored to its project: digits, ids and temp paths
    /// normalized. Nil for native binaries.
    static func workloadFingerprint(_ tokens: WorkloadTokens) -> String? {
        guard WorkloadTokens.isInterpreter(tokens.argv0) || WorkloadTokens.isInterpreter(tokens.executable),
              let script = tokens.script, !script.isEmpty
        else {
            return nil
        }
        if let path = tokens.scriptPath,
           ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"].contains(where: path.hasPrefix) {
            return "<tmp>"
        }
        // The same tool in two projects is two workloads, not two copies.
        var project = ""
        if let path = tokens.scriptPath, path.hasPrefix("/") {
            if let range = path.range(of: "/node_modules/") {
                project = String(path[..<range.lowerBound]) + "|"
            } else if let slash = path.lastIndex(of: "/") {
                project = String(path[..<slash]) + "|"
            }
        }
        if script.count >= 12, script.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            return project + "<id>"
        }
        var normalized = project
        var inDigits = false
        for character in script {
            if character.isASCII, character.isNumber {
                if !inDigits { normalized.append("#") }
                inDigits = true
            } else {
                normalized.append(character)
                inDigits = false
            }
        }
        return normalized
    }

    private func commandPrefix(_ command: String) -> String {
        command
            .split(whereSeparator: \.isWhitespace)
            .prefix(4)
            .map { piece in
                if ProcessSignature.isDecimalDigits(piece) {
                    return "<num>"
                }
                let token = piece.lowercased()
                if token.hasPrefix("/private/var/") || token.hasPrefix("/var/folders/") {
                    return "<tmp>"
                }
                return token
            }
            .joined(separator: " ")
    }

    private static func sortClusters(_ lhs: DuplicateProcessCluster, _ rhs: DuplicateProcessCluster) -> Bool {
        if lhs.memberCount != rhs.memberCount {
            return lhs.memberCount > rhs.memberCount
        }
        if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes {
            return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes
        }
        if lhs.totalCPUPercent != rhs.totalCPUPercent {
            return lhs.totalCPUPercent > rhs.totalCPUPercent
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}
