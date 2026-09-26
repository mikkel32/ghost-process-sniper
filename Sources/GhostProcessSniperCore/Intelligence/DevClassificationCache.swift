import Foundation

final class LockedDevClassificationCache: @unchecked Sendable {
    private struct Entry {
        var fingerprint: UInt64
        var classification: DevClassification
    }

    private let lock = NSLock()
    private var entries: [ProcessIdentity: Entry] = [:]
    private var pruneCounter = 0

    func classification(for process: ProcessMetrics, classifier: DevProcessClassifier) -> DevClassification {
        let fingerprint = Self.fingerprint(for: process)
        lock.lock()
        if let entry = entries[process.identity], entry.fingerprint == fingerprint {
            lock.unlock()
            return entry.classification
        }
        lock.unlock()

        let classification = classifier.classification(for: process)
        lock.lock()
        entries[process.identity] = Entry(fingerprint: fingerprint, classification: classification)
        pruneCounter += 1
        if pruneCounter >= 2_048, entries.count > 12_000 {
            let keep = Set(entries.keys.suffix(8_000))
            entries = entries.filter { keep.contains($0.key) }
            pruneCounter = 0
        }
        lock.unlock()
        return classification
    }

    private static func fingerprint(for process: ProcessMetrics) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(process.name)
        hasher.combine(process.executablePath)
        hasher.combine(process.commandLine)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
