import Foundation

/// Keeps each alert gate's memory across launches, as JSON in the user's
/// defaults. Anything unreadable is an empty memory: the worst outcome is one
/// repeated alert, never a lost setting or a crash.
public struct AlertMemoryStore: Sendable {
    public enum Gate: String, Sendable {
        case sentinel, energy

        var key: String { "Alerts.\(rawValue).v1" }
    }

    private let read: @Sendable (String) -> Data?
    private let write: @Sendable (Data, String) -> Void

    /// Reads and writes raw values by key; tests pass an in-memory shelf.
    public init(read: @escaping @Sendable (String) -> Data?, write: @escaping @Sendable (Data, String) -> Void) {
        self.read = read
        self.write = write
    }

    public static let standard = AlertMemoryStore(
        read: { UserDefaults.standard.data(forKey: $0) },
        write: { UserDefaults.standard.set($0, forKey: $1) }
    )

    public func load(_ gate: Gate) -> AlertMemory {
        read(gate.key).flatMap { try? JSONDecoder().decode(AlertMemory.self, from: $0) } ?? AlertMemory()
    }

    public func save(_ memory: AlertMemory, for gate: Gate) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        write(data, gate.key)
    }
}
