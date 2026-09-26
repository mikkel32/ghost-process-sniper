import Foundation

public struct CleanupDuplicateProof: Sendable {
    public let keeper: CleanupItem
    public let digest: String
}

public struct CleanupPlan: Identifiable, Sendable {
    public let id = UUID()
    public let items: [CleanupItem]
    public let createdAt: Date
    public let proofs: [String: CleanupDuplicateProof]
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public init(items: [CleanupItem], duplicates: [CleanupDuplicateGroup] = [], createdAt: Date = Date()) throws {
        guard !items.isEmpty else { throw CleanupFailure("Select at least one item to review.") }
        let ids = Set(items.map(\.id))
        guard ids.count == items.count else { throw CleanupFailure("An item was selected more than once.") }
        let ordered = items.sorted { $0.id < $1.id }
        for (index, item) in ordered.enumerated() {
            if ordered.dropFirst(index + 1).contains(where: { CleanupFileSystem.contains($0.url, in: item.url) }) {
                throw CleanupFailure("A folder and one of its contents are both selected. Review them separately.")
            }
        }
        var proofs: [String: CleanupDuplicateProof] = [:]
        for group in duplicates where group.files.contains(where: { ids.contains($0.id) }) {
            guard let keeper = group.files.first(where: { !ids.contains($0.id) }) else {
                throw CleanupFailure("Keep at least one copy of every duplicate group.")
            }
            guard !items.contains(where: { CleanupFileSystem.contains(keeper.url, in: $0.url) }) else {
                throw CleanupFailure("The retained duplicate is inside a selected folder.")
            }
            for file in group.files where ids.contains(file.id) {
                proofs[file.id] = CleanupDuplicateProof(keeper: keeper, digest: group.digest)
            }
        }
        self.items = ordered; self.createdAt = createdAt; self.proofs = proofs
    }
}

public enum CleanupReceiptState: String, Codable, Sendable { case pending, trashed, restored, failed }

public struct CleanupReceipt: Identifiable, Codable, Sendable {
    public let id: UUID
    public let transactionID: UUID
    public let date: Date
    public let item: CleanupItem
    public var state: CleanupReceiptState
    public var trashURL: URL?
    public var trashStamp: CleanupStamp?
    public var message: String?
}
