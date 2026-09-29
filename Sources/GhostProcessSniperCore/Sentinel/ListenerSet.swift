import Foundation

/// Exactly one listener per watched object: objects no longer wanted lose
/// theirs, new ones get one, and an object counts as watched only once its
/// listener was added. A device list that changes back and forth therefore
/// never piles listeners up.
struct ListenerSet<ID: Hashable>: Sendable where ID: Sendable {
    private(set) var watched: Set<ID> = []

    mutating func sync(to wanted: Set<ID>, add: (ID) -> Bool, remove: (ID) -> Void) {
        for id in watched.subtracting(wanted) {
            remove(id)
            watched.remove(id)
        }
        for id in wanted.subtracting(watched) where add(id) {
            watched.insert(id)
        }
    }
}
