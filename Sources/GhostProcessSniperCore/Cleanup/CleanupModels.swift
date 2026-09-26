import Foundation

public enum CleanupCategory: String, CaseIterable, Codable, Sendable {
    case caches, logs, installers, largeFiles, duplicates, appData, application

    public var title: String {
        switch self {
        case .caches: "App caches"
        case .logs: "Old logs"
        case .installers: "Old installers"
        case .largeFiles: "Large files"
        case .duplicates: "Duplicate file"
        case .appData: "App data"
        case .application: "Application"
        }
    }

    public var explanation: String {
        switch self {
        case .caches: "Cached files older than 30 days. Apps may rebuild them or download content again."
        case .logs: "Logs older than 30 days. Keep these if you are investigating a problem."
        case .installers: "Disk images and installer packages older than 30 days. Review before removing."
        case .largeFiles: "Files over 100 MB. Size alone does not mean a file is unnecessary."
        case .duplicates: "Matching file content. Names, dates and other metadata may differ; retain the copy you need."
        case .appData: "Local app settings or data. Resetting can remove preferences, sessions and saved work."
        case .application: "The application bundle. Subscriptions and external services are not cancelled."
        }
    }
}

public struct CleanupStamp: Hashable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modified: Int64
    public let changed: Int64
    public let isDirectory: Bool
    public let links: UInt64
    public let owner: UInt32
}

public struct CleanupItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let scope: URL
    public let category: CleanupCategory
    public let bytes: Int64
    public let stamp: CleanupStamp
    public let treeSignature: String?
    public let bundleID: String?
    public var name: String { url.lastPathComponent }

    public init(url: URL, scope: URL, category: CleanupCategory, bytes: Int64,
                stamp: CleanupStamp, treeSignature: String? = nil, bundleID: String? = nil) {
        self.url = url; self.scope = scope; self.category = category; self.bytes = bytes
        self.stamp = stamp; self.treeSignature = treeSignature; self.bundleID = bundleID
    }
}

public struct CleanupDuplicateGroup: Identifiable, Sendable {
    public let digest: String
    public let files: [CleanupItem]
    public var id: String { digest }
    public var extraBytes: Int64 { files.dropFirst().reduce(0) { $0 + $1.bytes } }
}

public struct CleanupScanOptions: Sendable {
    public var folders: [URL]
    public var includeCaches: Bool
    public var includeLogs: Bool
    public var findDuplicates: Bool
    public var maxEntries: Int
    public var hashByteBudget: Int64
    public var largeFileBytes: Int64
    public var oldBefore: Date

    public init(folders: [URL] = [], includeCaches: Bool = true, includeLogs: Bool = true,
                findDuplicates: Bool = true, maxEntries: Int = 100_000,
                hashByteBudget: Int64 = 8 * 1_024 * 1_024 * 1_024,
                largeFileBytes: Int64 = 100 * 1_024 * 1_024,
                oldBefore: Date = Date().addingTimeInterval(-30 * 86_400)) {
        self.folders = folders; self.includeCaches = includeCaches; self.includeLogs = includeLogs
        self.findDuplicates = findDuplicates; self.maxEntries = maxEntries
        self.hashByteBudget = hashByteBudget; self.largeFileBytes = largeFileBytes
        self.oldBefore = oldBefore
    }
}

public struct CleanupProgress: Sendable {
    public let phase: String
    public let visited: Int
    public let path: String
}

public struct CleanupScan: Sendable {
    public let date: Date
    public let items: [CleanupItem]
    public let duplicates: [CleanupDuplicateGroup]
    public let visited: Int
    public let skipped: Int
    public let notices: [String]
    public let isPartial: Bool
    public let capacity: Int64?
    public let available: Int64?

    public var allFiles: [CleanupItem] {
        var seen = Set<String>()
        return (items + duplicates.flatMap(\.files)).filter { seen.insert($0.id).inserted }
    }
}

public struct CleanupApplication: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let isProtected: Bool
}

public struct CleanupAppReview: Sendable {
    public let app: CleanupApplication
    public let items: [CleanupItem]
    public let notices: [String]
}

public struct CleanupFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
