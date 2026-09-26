import Foundation

public struct ProcessTelemetryCache: Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let executablePath: String
        public let commandLine: String
        public let ownerName: String
        public let refreshedAt: Date
        /// A name-only stand-in for telemetry that has not been read yet. It is
        /// never cached, never fresh and never counted as a cache hit.
        public let isPlaceholder: Bool
        /// argv was read, or found unreadable. A path-only entry still waits for the argv lane.
        let argumentsRead: Bool
        /// The BSD name the entry was read under. The same identity under a new
        /// name has exec'd, so the entry no longer describes it.
        let kernelName: String

        init(name: String, executablePath: String, commandLine: String, ownerName: String, refreshedAt: Date,
             isPlaceholder: Bool = false, argumentsRead: Bool = true, kernelName: String = "") {
            self.name = name
            self.executablePath = executablePath
            self.commandLine = commandLine
            self.ownerName = ownerName
            self.refreshedAt = refreshedAt
            self.isPlaceholder = isPlaceholder
            self.argumentsRead = argumentsRead
            self.kernelName = kernelName
        }

        static func placeholder(name: String, ownerName: String) -> Entry {
            Entry(name: name, executablePath: "", commandLine: name, ownerName: ownerName,
                  refreshedAt: .distantPast, isPlaceholder: true, argumentsRead: false)
        }
    }

    private var entries: [ProcessIdentity: Entry] = [:]

    public init() {}

    public func entry(for identity: ProcessIdentity) -> Entry? {
        entries[identity]
    }

    public mutating func update(_ entry: Entry, for identity: ProcessIdentity) {
        guard !entry.isPlaceholder else { return }
        entries[identity] = entry
    }

    mutating func remove(_ identity: ProcessIdentity) {
        entries[identity] = nil
    }

    public mutating func prune(keeping identities: Set<ProcessIdentity>) {
        entries = entries.filter { identities.contains($0.key) }
    }
}

public struct ForensicsCache: Sendable {
    public struct Entry: Equatable, Sendable {
        public let forensics: ProcessForensics
        public let refreshedAt: Date
        /// Only the port census has read this process; cwd and fd counts are unknown.
        public let isPortsOnly: Bool
        /// When the listening ports were last read, by a full read or the census.
        public let portsRefreshedAt: Date

        init(forensics: ProcessForensics, refreshedAt: Date, isPortsOnly: Bool = false, portsRefreshedAt: Date? = nil) {
            self.forensics = forensics
            self.refreshedAt = refreshedAt
            self.isPortsOnly = isPortsOnly
            self.portsRefreshedAt = portsRefreshedAt ?? refreshedAt
        }
    }

    private var entries: [ProcessIdentity: Entry] = [:]

    public init() {}

    public func entry(for identity: ProcessIdentity, now: Date, maxAge: TimeInterval) -> Entry? {
        guard let entry = entries[identity], now.timeIntervalSince(entry.refreshedAt) <= maxAge else {
            return nil
        }
        return entry
    }

    public func entry(for identity: ProcessIdentity) -> Entry? {
        entries[identity]
    }

    public func negativeEntry(for identity: ProcessIdentity, now: Date, maxAge: TimeInterval) -> Entry? {
        guard let entry = entries[identity],
              entry.forensics.isPartial, !entry.isPortsOnly,
              now.timeIntervalSince(entry.refreshedAt) <= maxAge
        else {
            return nil
        }
        return entry
    }

    public mutating func update(_ forensics: ProcessForensics, for identity: ProcessIdentity, at date: Date) {
        entries[identity] = Entry(forensics: forensics, refreshedAt: date)
    }

    /// Folds a ports-only census into the entry, keeping a full read's other
    /// facts and its age, and returns what the process should now show.
    @discardableResult
    mutating func mergePorts(_ ports: Set<Int>, for identity: ProcessIdentity, at date: Date) -> ProcessForensics {
        let listening = ListeningSocketReader.storedPorts(ports)
        if let entry = entries[identity], !entry.isPortsOnly {
            let old = entry.forensics
            let merged = ProcessForensics(currentDirectory: old.currentDirectory, rootDirectory: old.rootDirectory,
                openFileCount: old.openFileCount, socketCount: old.socketCount, listeningPorts: listening,
                isPartial: old.isPartial, notes: old.notes)
            entries[identity] = Entry(forensics: merged, refreshedAt: entry.refreshedAt, portsRefreshedAt: date)
            return merged
        }
        let census = ProcessForensics(currentDirectory: nil, rootDirectory: nil, openFileCount: nil, socketCount: nil,
            listeningPorts: listening, isPartial: true, notes: ["ports only"])
        entries[identity] = Entry(forensics: census, refreshedAt: date, isPortsOnly: true)
        return census
    }

    mutating func remove(_ identity: ProcessIdentity) {
        entries[identity] = nil
    }

    public mutating func prune(keeping identities: Set<ProcessIdentity>) {
        entries = entries.filter { identities.contains($0.key) }
    }
}

public struct ProcessRecord: Equatable, Sendable {
    public let identity: ProcessIdentity
    public var process: ProcessMetrics
    public var telemetryRefreshedAt: Date

    public init(identity: ProcessIdentity, process: ProcessMetrics, telemetryRefreshedAt: Date) {
        self.identity = identity
        self.process = process
        self.telemetryRefreshedAt = telemetryRefreshedAt
    }
}

public struct ProcessScanCache: Sendable {
    private var records: [ProcessIdentity: ProcessRecord] = [:]

    public init() {}

    public func record(for identity: ProcessIdentity) -> ProcessRecord? {
        records[identity]
    }

    public mutating func update(_ record: ProcessRecord) {
        records[record.identity] = record
    }

    public mutating func prune(keeping identities: Set<ProcessIdentity>) {
        records = records.filter { identities.contains($0.key) }
    }

    /// A record whose telemetry was a placeholder carries `.distantPast`, so it is always due.
    public func shouldRefreshTelemetry(
        identity: ProcessIdentity,
        now: Date,
        maxAge: TimeInterval,
        grace: TimeInterval,
        isPriority: Bool
    ) -> Bool {
        guard let record = records[identity] else {
            return true
        }
        let age = now.timeIntervalSince(record.telemetryRefreshedAt)
        let refreshAge = isPriority ? maxAge : maxAge + grace
        return age > refreshAge
    }
}
