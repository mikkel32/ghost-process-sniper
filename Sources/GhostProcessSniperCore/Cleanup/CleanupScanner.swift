import Foundation

public actor CleanupScanner {
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.resolvingSymlinksInPath()
    }

    public func scan(_ options: CleanupScanOptions,
                     progress: @Sendable (CleanupProgress) -> Void = { _ in }) throws -> CleanupScan {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .isPackageKey, .isAliasFileKey, .isUbiquitousItemKey, .contentModificationDateKey]
        var scopes: [(URL, CleanupCategory?)] = []
        var notices: [String] = []
        for folder in options.folders {
            let root = folder.standardizedFileURL
            let forbidden = [home.appendingPathComponent("Library"), home.appendingPathComponent(".Trash"),
                             home.appendingPathComponent("Applications")]
            guard root.path == root.resolvingSymlinksInPath().path,
                  CleanupFileSystem.contains(root, in: home),
                  !forbidden.contains(where: { root == $0 || CleanupFileSystem.contains(root, in: $0) }) else {
                notices.append("Choose a local folder inside your home, outside Library and Applications: \(root.path)")
                continue
            }
            if !scopes.contains(where: { root == $0.0 || CleanupFileSystem.contains(root, in: $0.0) }) {
                scopes.removeAll { CleanupFileSystem.contains($0.0, in: root) }
                scopes.append((root, nil))
            }
        }
        if options.includeCaches { scopes.append((home.appendingPathComponent("Library/Caches"), .caches)) }
        if options.includeLogs { scopes.append((home.appendingPathComponent("Library/Logs"), .logs)) }
        var items: [CleanupItem] = []
        var possibleDuplicates: [Int64: [CleanupItem]] = [:]
        var visited = 0
        var skipped = 0
        var partial = !notices.isEmpty
        var seenPaths = Set<String>()
        let ignoredFolders: Set<String> = ["node_modules", ".git", ".build", ".Trash", "Library"]
        for (root, category) in scopes {
            try Task.checkCancellation()
            guard fm.fileExists(atPath: root.path) else { continue }
            guard root.path == root.resolvingSymlinksInPath().path else {
                notices.append("Linked folder excluded: \(root.path)"); partial = true; continue
            }
            var scanErrors = 0
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in scanErrors += 1; return true }) else {
                notices.append("Access unavailable: \(root.path)"); partial = true; continue
            }
            for case let url as URL in walker {
                try Task.checkCancellation()
                guard visited < max(1, options.maxEntries) else { partial = true; break }
                visited += 1
                if visited % 128 == 1 { progress(.init(phase: "Inspecting files", visited: visited, path: root.path)) }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true || values.isPackage == true || values.isUbiquitousItem == true ||
                       values.isAliasFile == true || (category == nil && ignoredFolders.contains(url.lastPathComponent)) {
                        walker.skipDescendants(); skipped += 1; continue
                    }
                    guard values.isRegularFile == true, seenPaths.insert(url.path).inserted else { continue }
                    try CleanupFileSystem.checkedPath(url, scope: root)
                    let identity = try CleanupFileSystem.stamp(url)
                    guard identity.size > 0, identity.links == 1 else { skipped += 1; continue }
                    let old = (values.contentModificationDate ?? .distantFuture) < options.oldBefore
                    let installer = ["dmg", "pkg", "mpkg", "iso"].contains(url.pathExtension.lowercased())
                    let type = category ?? (installer && old ? .installers : .largeFiles)
                    let appID: String? = category != nil ? url.path.dropFirst(root.path.count + 1).split(separator: "/").first.map(String.init) : nil
                    let item = CleanupItem(url: url, scope: root, category: type, bytes: identity.size,
                        stamp: identity, bundleID: appID.flatMap { CleanupApplications.validBundleID($0) ? $0 : nil })
                    if category != nil ? old : (installer && old || identity.size >= options.largeFileBytes) {
                        items.append(item)
                    }
                    if category == nil, options.findDuplicates, !CleanupFileSystem.hasResourceFork(url) {
                        let candidate = CleanupItem(url: url, scope: root, category: .duplicates,
                            bytes: identity.size, stamp: identity)
                        possibleDuplicates[identity.size, default: []].append(candidate)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { skipped += 1; partial = true }
            }
            if scanErrors > 0 {
                notices.append("\(scanErrors) locations could not be read in \(root.lastPathComponent). Review permissions in System Settings.")
                partial = true
            }
            if visited >= max(1, options.maxEntries) {
                notices.append("The \(options.maxEntries)-entry scan limit was reached. Choose smaller folders to finish.")
                break
            }
        }
        var groups: [CleanupDuplicateGroup] = []
        var hashed: Int64 = 0
        var hashLimited = false
        for size in possibleDuplicates.keys.sorted() {
            guard let candidates = possibleDuplicates[size], candidates.count > 1 else { continue }
            var matching: [String: [CleanupItem]] = [:]
            for file in candidates.sorted(by: { $0.url.path < $1.url.path }) {
                try Task.checkCancellation()
                guard size <= options.hashByteBudget - hashed else { hashLimited = true; continue }
                hashed += size
                progress(.init(phase: "Comparing file contents", visited: visited, path: file.name))
                do { matching[try CleanupFileSystem.digest(file.url, expected: file.stamp), default: []].append(file) }
                catch is CancellationError { throw CancellationError() }
                catch { skipped += 1; partial = true }
            }
            for (digest, files) in matching where files.count > 1 {
                // Oldest copy is suggested; the user can choose another keeper.
                let ordered = files.sorted { $0.stamp.modified == $1.stamp.modified ? $0.id < $1.id : $0.stamp.modified < $1.stamp.modified }
                groups.append(CleanupDuplicateGroup(digest: digest, files: ordered))
            }
        }
        if hashLimited {
            notices.append("Duplicate comparison reached its 8 GB default read budget. Some files were not compared; scan a smaller folder.")
            partial = true
        }
        let capacity = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return CleanupScan(date: Date(), items: items.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes },
            duplicates: groups.sorted { $0.extraBytes == $1.extraBytes ? $0.id < $1.id : $0.extraBytes > $1.extraBytes },
            visited: visited, skipped: skipped, notices: notices, isPartial: partial,
            capacity: capacity?.volumeTotalCapacity.map(Int64.init), available: capacity?.volumeAvailableCapacity.map(Int64.init))
    }
}
