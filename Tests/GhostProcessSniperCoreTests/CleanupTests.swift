import Foundation
import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class CleanupTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/cleanup-tests/\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Trash"), withIntermediateDirectories: true)
        return root
    }

    private func file(_ name: String, root: URL, text: String = "fixture content") throws -> CleanupItem {
        let url = root.appendingPathComponent("Downloads/\(name)")
        try Data(text.utf8).write(to: url)
        return .init(url: url, scope: root.appendingPathComponent("Downloads"), category: .largeFiles,
                     bytes: Int64(text.utf8.count), stamp: try CleanupFileSystem.stamp(url))
    }

    private func scan(_ root: URL, budget: Int64 = 1_048_576, limit: Int = 1_000) async throws -> CleanupScan {
        try await CleanupScanner(home: root).scan(.init(folders: [root.appendingPathComponent("Downloads")],
            includeCaches: false, includeLogs: false, maxEntries: limit, hashByteBudget: budget, largeFileBytes: 1))
    }

    private func transaction(_ root: URL) -> CleanupTransaction {
        CleanupTransaction(journalURL: root.appendingPathComponent("history/journal.json"),
            trashRoot: root.appendingPathComponent("Trash"), mover: { source in
                let destination = root.appendingPathComponent("Trash/\(UUID().uuidString)-\(source.lastPathComponent)")
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            })
    }

    func testDuplicatesUseContentsAndKeepDifferentSameSizeFiles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try file("one.txt", root: root, text: "same")
        _ = try file("two.txt", root: root, text: "same")
        _ = try file("three.txt", root: root, text: "diff")
        let result = try await scan(root)
        XCTAssertEqual(result.duplicates.count, 1)
        XCTAssertEqual(result.duplicates.first?.files.count, 2)
        XCTAssertEqual(result.duplicates.first?.extraBytes, 4)
        XCTAssertEqual(result.items.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Downloads/one.txt").path))
    }

    func testSymlinksAndHardlinksAreExcluded() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try file("original", root: root)
        try FileManager.default.linkItem(at: original.url, to: root.appendingPathComponent("Downloads/hardlink"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Downloads/link"), withDestinationURL: original.url)
        let result = try await scan(root)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.duplicates.isEmpty)
        XCTAssertGreaterThanOrEqual(result.skipped, 3)
    }

    func testHashAndEntryLimitsReportPartialScans() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try file("one", root: root); _ = try file("two", root: root)
        let budget = try await scan(root, budget: 1)
        XCTAssertTrue(budget.isPartial)
        XCTAssertTrue(budget.duplicates.isEmpty)
        XCTAssertFalse(budget.notices.isEmpty)
        let limited = try await scan(root, limit: 1)
        XCTAssertTrue(limited.isPartial)
        XCTAssertEqual(limited.visited, 1)
    }

    func testCannotSelectEveryDuplicateOrRepeatAnItem() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("one", root: root); _ = try file("two", root: root)
        let result = try await scan(root)
        XCTAssertThrowsError(try CleanupPlan(items: result.duplicates[0].files, duplicates: result.duplicates))
        XCTAssertThrowsError(try CleanupPlan(items: [one, one]))
    }

    func testPathBoundaryAndSelectedParentChecks() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("one", root: root)
        let parentURL = one.url.deletingLastPathComponent()
        let parent = CleanupItem(url: parentURL, scope: root, category: .appData, bytes: one.bytes,
                                 stamp: try CleanupFileSystem.stamp(parentURL))
        XCTAssertThrowsError(try CleanupPlan(items: [parent, one]))
        XCTAssertFalse(CleanupFileSystem.contains(URL(fileURLWithPath: "/Users/example-two/a"), in: URL(fileURLWithPath: "/Users/example")))
        XCTAssertThrowsError(try CleanupFileSystem.checkedPath(URL(fileURLWithPath: "/System/test"), scope: URL(fileURLWithPath: "/System")))
    }

    func testChangedSourceAbortsBeforeAnyMove() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("one", root: root)
        let plan = try CleanupPlan(items: [one])
        try Data("changed data".utf8).write(to: one.url)
        do { _ = try await transaction(root).execute(plan, runningApps: { [] }); XCTFail("Accepted changed file") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history/journal.json").path))
    }

    func testChangedKeeperPreventsDuplicateRemoval() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try file("one", root: root); _ = try file("two", root: root)
        let result = try await scan(root)
        let group = result.duplicates[0]
        let plan = try CleanupPlan(items: [group.files[1]], duplicates: [group])
        try Data("changed retained copy".utf8).write(to: group.files[0].url)
        do { _ = try await transaction(root).execute(plan, runningApps: { [] }); XCTFail("Removed without a valid keeper") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: group.files[1].url.path)) }
    }

    func testMoveJournalRestoreAndReplayProtection() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("one", root: root)
        let service = transaction(root)
        let plan = try CleanupPlan(items: [one])
        let outcomes = try await service.execute(plan, runningApps: { [] })
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].state, .trashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.url.path))
        try await service.restore(outcomes[0].id, runningApps: { [] })
        XCTAssertEqual(try String(contentsOf: one.url, encoding: .utf8), "fixture content")
        let history = try await service.history()
        XCTAssertEqual(history[0].state, .restored)
        do { _ = try await service.execute(plan, runningApps: { [] }); XCTFail("Replayed a used review") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already used")) }
    }

    func testRestoreNeverOverwritesNewFiles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("one", root: root)
        let service = transaction(root)
        let receipts = try await service.execute(try CleanupPlan(items: [one]), runningApps: { [] })
        try Data("new user data".utf8).write(to: one.url)
        do { try await service.restore(receipts[0].id, runningApps: { [] }); XCTFail("Overwrote a new file") }
        catch { XCTAssertTrue(error.localizedDescription.contains("occupied")) }
        XCTAssertEqual(try String(contentsOf: one.url, encoding: .utf8), "new user data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(receipts[0].trashURL).path))
    }

    func testRunningAppsAndExpiredReviewsAreRejected() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("one", root: root)
        let appItem = CleanupItem(url: one.url, scope: one.scope, category: .appData, bytes: one.bytes,
                                  stamp: one.stamp, bundleID: "com.example.fixture")
        do { _ = try await transaction(root).execute(try CleanupPlan(items: [appItem]), runningApps: { ["com.example.fixture"] }); XCTFail("Changed a running app") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Quit")) }
        do { _ = try await transaction(root).execute(try CleanupPlan(items: [one], createdAt: Date().addingTimeInterval(-301)), runningApps: { [] }); XCTFail("Accepted an expired review") }
        catch { XCTAssertTrue(error.localizedDescription.contains("expired")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.url.path))
    }

    func testDirectoryChangesInvalidateReview() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("one", root: root)
        let folder = one.url.deletingLastPathComponent()
        let measurement = try CleanupFileSystem.measure(folder)
        let item = CleanupItem(url: folder, scope: root, category: .appData, bytes: measurement.bytes,
                               stamp: try CleanupFileSystem.stamp(folder), treeSignature: measurement.signature)
        try Data("changed content".utf8).write(to: one.url)
        XCTAssertThrowsError(try CleanupFileSystem.validate(item))
    }

    func testPartialFailurePreservesSuccessfulReceipts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("a", root: root); let two = try file("b", root: root)
        let service = CleanupTransaction(journalURL: root.appendingPathComponent("history/journal.json"),
            trashRoot: root.appendingPathComponent("Trash"), mover: { url in
                if url.lastPathComponent == "b" { throw CleanupFailure("Injected move failure") }
                let destination = root.appendingPathComponent("Trash/a")
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        let result = try await service.execute(try CleanupPlan(items: [one, two]), runningApps: { [] })
        XCTAssertEqual(result.map(\.state), [.trashed, .failed])
        let history = try await service.history()
        XCTAssertEqual(history.map(\.state), [.trashed, .failed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: two.url.path))
    }

    func testUncertainMoveIsNotReportedAsVerifiedFailure() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try file("one", root: root)
        let remaining = try file("z-remaining", root: root)
        let service = CleanupTransaction(journalURL: root.appendingPathComponent("history/journal.json"),
            trashRoot: root.appendingPathComponent("Trash"), mover: { url in
                try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("Trash/one"))
                throw CleanupFailure("Injected error after move")
            })
        let result = try await service.execute(try CleanupPlan(items: [one, remaining]), runningApps: { [] })
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remaining.url.path))
        XCTAssertEqual(result[0].state, .pending)
        XCTAssertNil(result[0].trashURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.url.path))
    }

    func testCancellationPublishesNoPartialSuccess() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try file("one", root: root)
        let scanner = CleanupScanner(home: root)
        let task = Task {
            try Task.checkCancellation()
            return try await scanner.scan(.init(folders: [root.appendingPathComponent("Downloads")], includeCaches: false, includeLogs: false))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAppReviewIncludesOnlyExactBundleIDData() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications/Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        let id = "com.example.cleanupfixture"
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": id, "CFBundleName": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let exact = root.appendingPathComponent("Library/Caches/\(id)")
        let neighbor = root.appendingPathComponent("Library/Caches/\(id).other")
        try FileManager.default.createDirectory(at: exact, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        let subject = CleanupApplication(url: app, name: "Fixture", bundleID: id, version: "1", isProtected: false)
        let review = try await CleanupAppScanner(home: root).review(subject, uninstall: true)
        XCTAssertEqual(Set(review.items.map { $0.url.path }), Set([app.path, exact.path]))
        XCTAssertFalse(review.notices.isEmpty)
        XCTAssertFalse(CleanupApplications.validBundleID("../../Library"))
        XCTAssertFalse(CleanupApplications.validBundleID("com..example"))
    }
}
