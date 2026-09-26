import Foundation

/// Everything the family builder derives from a process's name, path and
/// command line. Those change only on exec, so each identity pays for the
/// string work once instead of on every tick.
struct ProcessStaticFacts: Sendable {
    let classification: DevClassification
    let signature: ProcessSignature
    let commandHint: String?
    /// Lowercased path through ".app/", for grouping one bundle's processes.
    let appBundlePrefix: String?
    /// The executable's directory; empty when the path is empty or relative.
    let parentDirectory: String
    let isHelperNamed: Bool
    let isAppMainBinary: Bool
    let isHardwareEligible: Bool
    /// Nil when the process is not a duplicate candidate at all.
    let duplicateKey: DuplicateClusterKey?

    static func parentDirectory(of path: String) -> String {
        guard path.hasPrefix("/"), let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    static func appBundlePrefix(of path: String) -> String? {
        guard let range = path.range(of: ".app/", options: [.caseInsensitive]) else {
            return nil
        }
        return String(path[..<range.upperBound]).lowercased()
    }
}

/// Caches ProcessStaticFacts per identity across ticks. An exec keeps the
/// identity but changes the path or command, so an entry is reused only
/// while the path and the name and command lengths still match. Entries
/// unseen for two prune cycles are dropped.
final class ProcessStaticFactsCache: @unchecked Sendable {
    private struct Entry {
        var nameLength: Int
        var commandLength: Int
        var path: String
        var facts: ProcessStaticFacts
        var lastSeen: UInt64
    }

    static let pruneInterval: UInt64 = 16

    private let lock = NSLock()
    private var entries: [ProcessIdentity: Entry] = [:]
    private var generation: UInt64 = 0
    private var previousPrune: UInt64 = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// One lookup pass per build: `make` runs for new or exec'd identities.
    func facts(
        for processes: [ProcessMetrics],
        make: (ProcessMetrics) -> ProcessStaticFacts
    ) -> [ProcessStaticFacts] {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        var result: [ProcessStaticFacts] = []
        result.reserveCapacity(processes.count)
        for process in processes {
            let nameLength = process.name.utf8.count
            let commandLength = process.commandLine.utf8.count
            if let index = entries.index(forKey: process.identity) {
                let entry = entries.values[index]
                if entry.nameLength == nameLength, entry.commandLength == commandLength,
                   entry.path == process.executablePath {
                    entries.values[index].lastSeen = generation
                    result.append(entry.facts)
                    continue
                }
            }
            let facts = make(process)
            entries[process.identity] = Entry(
                nameLength: nameLength,
                commandLength: commandLength,
                path: process.executablePath,
                facts: facts,
                lastSeen: generation
            )
            result.append(facts)
        }
        if generation % Self.pruneInterval == 0 {
            let cutoff = previousPrune
            entries = entries.filter { $0.value.lastSeen > cutoff }
            previousPrune = generation - Self.pruneInterval
        }
        return result
    }
}
