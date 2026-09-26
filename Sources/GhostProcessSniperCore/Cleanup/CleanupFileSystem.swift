import CryptoKit
import Darwin
import Foundation

/// Shared identity and scope checks for scanning, confirmation and recovery.
public enum CleanupFileSystem {
    public static func contains(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let parent = root.standardizedFileURL.path
        return path.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    public static func stamp(_ url: URL) throws -> CleanupStamp {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0 else { throw CleanupFailure("Cannot inspect \(url.path): \(String(cString: strerror(errno)))") }
        let kind = value.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else {
            throw CleanupFailure("Links and special files are excluded: \(url.path)")
        }
        return CleanupStamp(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), size: value.st_size,
            modified: Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec),
            changed: Int64(value.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(value.st_ctimespec.tv_nsec),
            isDirectory: kind == S_IFDIR, links: UInt64(value.st_nlink), owner: value.st_uid)
    }

    public static func checkedPath(_ url: URL, scope: URL) throws {
        guard url.isFileURL, scope.isFileURL, scope.path != "/",
              contains(url, in: scope),
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
              scope.standardizedFileURL.path == scope.resolvingSymlinksInPath().path else {
            throw CleanupFailure("The path or one of its parents changed, is linked, or is outside the reviewed folder.")
        }
        let blocked = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/dev"]
        if blocked.contains(where: { url.path == $0 || contains(url, in: URL(fileURLWithPath: $0)) }) {
            throw CleanupFailure("Protected macOS locations cannot be cleaned.")
        }
    }

    public static func digest(_ url: URL, expected: CleanupStamp) throws -> String {
        guard !expected.isDirectory, expected.links == 1 else { throw CleanupFailure("Not an independent regular file.") }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { throw CleanupFailure("Cannot read \(url.lastPathComponent).") }
        defer { Darwin.close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, UInt64(value.st_ino) == expected.inode,
              UInt64(value.st_dev) == expected.device, value.st_size == expected.size,
              value.st_mode & S_IFMT == S_IFREG else { throw CleanupFailure("File changed before comparison.") }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 { throw CleanupFailure("File could not be fully compared.") }
            total += Int64(count)
            guard total <= expected.size else { throw CleanupFailure("File grew during comparison.") }
            hash.update(data: Data(buffer.prefix(count)))
        }
        guard total == expected.size, try stamp(url) == expected else { throw CleanupFailure("File changed during comparison.") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func hasResourceFork(_ url: URL) -> Bool {
        let size = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return getxattr(path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        }
        return size > 0
    }

    /// Includes hidden entries in directory review; no linked descendants are followed.
    public static func measure(_ url: URL, limit: Int = 100_000) throws -> (bytes: Int64, signature: String?) {
        let original = try stamp(url)
        if !original.isDirectory { return (max(0, original.size), nil) }
        var failure: Error?
        guard let walker = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isUbiquitousItemKey],
                options: [], errorHandler: { _, error in failure = error; return false }) else {
            throw CleanupFailure("Cannot inspect all contents of \(url.lastPathComponent).")
        }
        var bytes: Int64 = 0
        var entries: [String] = []
        for case let child as URL in walker {
            try Task.checkCancellation()
            guard entries.count < limit else { throw CleanupFailure("Folder exceeds the review limit; inspect it in Finder.") }
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isUbiquitousItemKey])
            guard values.isUbiquitousItem != true else { throw CleanupFailure("Cloud-managed content requires review in Finder.") }
            let relative = String(child.path.dropFirst(url.path.count))
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                entries.append(relative + "|link|" + (try FileManager.default.destinationOfSymbolicLink(atPath: child.path)))
                continue
            }
            let identity = try stamp(child)
            if !identity.isDirectory { bytes += max(0, identity.size) }
            entries.append("\(relative)|\(identity.device)|\(identity.inode)|\(identity.size)|\(identity.modified)|\(identity.changed)")
        }
        if let failure { throw failure }
        guard try stamp(url) == original else { throw CleanupFailure("Folder changed while it was being reviewed.") }
        let data = Data(entries.sorted().joined(separator: "\n").utf8)
        let signature = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (bytes, signature)
    }

    public static func validate(_ item: CleanupItem) throws {
        try checkedPath(item.url, scope: item.scope)
        guard try stamp(item.url) == item.stamp else { throw CleanupFailure("\(item.name) changed. Scan again before cleaning.") }
        guard item.stamp.owner == getuid() else { throw CleanupFailure("This item is owned by another user. Use Finder to manage it.") }
        if let signature = item.treeSignature {
            guard try measure(item.url).signature == signature else { throw CleanupFailure("Contents of \(item.name) changed. Review it again.") }
        }
    }
}
