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
              entry.forensics.isPartial,
              now.timeIntervalSince(entry.refreshedAt) <= maxAge
        else {
            return nil
        }
        return entry
    }

    public mutating func update(_ forensics: ProcessForensics, for identity: ProcessIdentity, at date: Date) {
        entries[identity] = Entry(forensics: forensics, refreshedAt: date)
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
