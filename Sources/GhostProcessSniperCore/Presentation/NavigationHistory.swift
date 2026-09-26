import Foundation

/// The console's Back/Forward trail. Revisiting the current page is not a
/// new step, and families that have exited are dropped before moving so Back
/// never lands on "Process no longer running".
public struct NavigationHistory: Equatable, Sendable {
    public static let capacity = 30

    public private(set) var entries: [RadarFocusedSelection] = []
    public private(set) var index = -1

    public init() {}

    public var current: RadarFocusedSelection? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    /// The page before the current one, without moving.
    public var previous: RadarFocusedSelection? {
        entries.indices.contains(index - 1) ? entries[index - 1] : nil
    }

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    public mutating func visit(_ selection: RadarFocusedSelection) {
        guard selection != current else { return }
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(selection)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        index = entries.count - 1
    }

    public mutating func goBack() -> RadarFocusedSelection? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    public mutating func goForward() -> RadarFocusedSelection? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }

    /// Drops family pages whose key is no longer live. The current page stays
    /// even when its family is gone: the user is looking at it, and Back
    /// must still step to the page before it.
    public mutating func prune(liveFamilyKeys: Set<String>) {
        var kept: [RadarFocusedSelection] = []
        var newIndex = -1
        for (offset, entry) in entries.enumerated() {
            let isDead = entry.familyKey.map { !liveFamilyKeys.contains($0) } ?? false
            if isDead, offset != index { continue }
            // Removing a page can leave the same page twice in a row.
            if entry != kept.last { kept.append(entry) }
            if offset <= index { newIndex = kept.count - 1 }
        }
        entries = kept
        index = kept.isEmpty ? -1 : max(0, newIndex)
    }
}
