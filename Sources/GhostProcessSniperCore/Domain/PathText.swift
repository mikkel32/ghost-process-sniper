import Foundation

/// Path splitting for hot loops. URL(fileURLWithPath:) stats the path to decide
/// whether it is a directory; these helpers only look at the characters.
enum PathText {
    static func lastComponent(_ path: Substring) -> Substring {
        let trimmed = trimmingTrailingSlashes(path)
        guard !trimmed.isEmpty else { return path.isEmpty ? path : path.prefix(1) }
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return trimmed[trimmed.index(after: slash)...]
    }

    /// A leading dot names a hidden file, not an extension.
    static func deletingExtension(_ name: Substring) -> Substring {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return name }
        return name[..<dot]
    }

    static func parent(_ path: String) -> String {
        let trimmed = trimmingTrailingSlashes(path[...])
        guard !trimmed.isEmpty else { return path.isEmpty ? "" : "/" }
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    /// "/Applications/Google Chrome.app" -> "Google Chrome".
    static func displayName(_ path: String) -> String {
        String(deletingExtension(lastComponent(path[...])))
    }

    private static func trimmingTrailingSlashes(_ path: Substring) -> Substring {
        var end = path.endIndex
        while end > path.startIndex, path[path.index(before: end)] == "/" { end = path.index(before: end) }
        return path[..<end]
    }
}
