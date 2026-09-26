import Foundation

/// All file changes go through a reviewed, expiring plan. No permanent-delete fallback.
public actor CleanupTransaction {
    public typealias TrashMover = @Sendable (URL) throws -> URL
    private let journalURL: URL
    private let trashRoot: URL
    private let mover: TrashMover
    private var consumedPlans = Set<UUID>()
    private var busy = false

    public init(journalURL: URL? = nil, trashRoot: URL? = nil, mover: TrashMover? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        self.journalURL = journalURL ?? home.appendingPathComponent("Library/Application Support/GhostProcessSniper/Cleanup/history.json")
        self.trashRoot = trashRoot ?? home.appendingPathComponent(".Trash")
        self.mover = mover ?? { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let result = resultingURL as URL? else {
                throw CleanupFailure("macOS moved the item but did not return its Trash location. Check Finder; do not repeat the operation.")
            }
            return result
        }
    }

    public func history() throws -> [CleanupReceipt] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        return try JSONDecoder().decode([CleanupReceipt].self, from: Data(contentsOf: journalURL))
    }

    public func execute(_ plan: CleanupPlan,
        runningApps: @Sendable () async -> Set<String> = { await CleanupApplications.runningBundleIDs() }
    ) async throws -> [CleanupReceipt] {
        guard !busy else { throw CleanupFailure("Another cleanup or restore is still running.") }
        guard !consumedPlans.contains(plan.id) else { throw CleanupFailure("This review was already used. Create a new review.") }
        let age = Date().timeIntervalSince(plan.createdAt)
        guard age >= 0, age < 300 else { throw CleanupFailure("This review expired. Review your selection again.") }
        busy = true
        defer { busy = false }
        consumedPlans.insert(plan.id)
        // Validate the complete selection before admitting the first change.
        let running = await runningApps()
        for item in plan.items {
            try Task.checkCancellation()
            try validate(item, proof: plan.proofs[item.id], running: running)
        }
        var journal = try history()
        var outcomes: [CleanupReceipt] = []
        for item in plan.items {
            if Task.isCancelled { break }
            var receipt = CleanupReceipt(id: UUID(), transactionID: plan.id, date: Date(), item: item,
                                         state: .pending, trashURL: nil, trashStamp: nil, message: nil)
            journal.append(receipt)
            // Record intent first: an interrupted move is never automatically retried.
            try persist(journal)
            do {
                let liveApps = await runningApps()
                try Task.checkCancellation()
                try validate(item, proof: plan.proofs[item.id], running: liveApps)
                let destination = try mover(item.url)
                receipt.state = .trashed
                receipt.trashURL = destination
                receipt.trashStamp = try? CleanupFileSystem.stamp(destination)
            } catch {
                // An absent source after an error is an uncertain move, never a retry instruction.
                receipt.state = FileManager.default.fileExists(atPath: item.url.path) ? .failed : .pending
                receipt.message = error.localizedDescription
            }
            journal[journal.count - 1] = receipt
            outcomes.append(receipt)
            do { try persist(journal) }
            catch {
                throw CleanupFailure("Cleanup stopped because the recovery journal could not be updated. Inspect Trash before retrying. \(error.localizedDescription)")
            }
            if receipt.state == .pending { break }
        }
        return outcomes
    }

    public func restore(_ id: UUID,
        runningApps: @Sendable () async -> Set<String> = { await CleanupApplications.runningBundleIDs() }
    ) async throws {
        guard !busy else { throw CleanupFailure("Another cleanup or restore is still running.") }
        busy = true
        defer { busy = false }
        var journal = try history()
        guard let index = journal.firstIndex(where: { $0.id == id }), journal[index].state == .trashed,
              let trash = journal[index].trashURL, let identity = journal[index].trashStamp else {
            throw CleanupFailure("No verified Trash item is available. Inspect it in Finder.")
        }
        let receipt = journal[index]
        try CleanupFileSystem.checkedPath(receipt.item.url, scope: receipt.item.scope)
        guard CleanupFileSystem.contains(trash, in: trashRoot),
              trash.path == trash.resolvingSymlinksInPath().path,
              try CleanupFileSystem.stamp(trash) == identity else {
            throw CleanupFailure("The item in Trash changed or is no longer available.")
        }
        let running = await runningApps()
        try checkRunning(receipt.item, running: running)
        // A dangling link also counts as an occupied destination.
        guard !FileManager.default.fileExists(atPath: receipt.item.url.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: receipt.item.url.path)) == nil else {
            throw CleanupFailure("The original path is occupied. Move or rename that item in Finder first; nothing was overwritten.")
        }
        let parent = receipt.item.url.deletingLastPathComponent()
        guard try CleanupFileSystem.stamp(parent).isDirectory else { throw CleanupFailure("The original folder no longer exists.") }
        try FileManager.default.moveItem(at: trash, to: receipt.item.url)
        journal[index].state = .restored
        do { try persist(journal) }
        catch { throw CleanupFailure("The item was restored, but its journal update failed. Check the original location before retrying.") }
    }

    private func validate(_ item: CleanupItem, proof: CleanupDuplicateProof?, running: Set<String>) throws {
        try CleanupFileSystem.validate(item)
        try checkRunning(item, running: running)
        if let proof {
            try CleanupFileSystem.validate(proof.keeper)
            guard try CleanupFileSystem.digest(proof.keeper.url, expected: proof.keeper.stamp) == proof.digest,
                  try CleanupFileSystem.digest(item.url, expected: item.stamp) == proof.digest else {
                throw CleanupFailure("Duplicate content changed. Scan the folder again.")
            }
        }
    }

    private func checkRunning(_ item: CleanupItem, running: Set<String>) throws {
        if let bundleID = item.bundleID {
            guard !running.contains(bundleID) else { throw CleanupFailure("Quit \(bundleID) before changing its files. No app will be force-quit.") }
            if item.category == .appData || item.category == .application {
                guard !bundleID.hasPrefix("com.apple."), bundleID != "com.local.GhostProcessSniper",
                      bundleID != Bundle.main.bundleIdentifier else { throw CleanupFailure("This app is protected.") }
            }
        }
    }

    private func persist(_ journal: [CleanupReceipt]) throws {
        let folder = journalURL.deletingLastPathComponent()
        guard folder.path == folder.resolvingSymlinksInPath().path else { throw CleanupFailure("Recovery folder is linked; cleanup was stopped.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
}
