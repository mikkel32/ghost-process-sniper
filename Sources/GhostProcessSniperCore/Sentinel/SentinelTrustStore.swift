import Foundation

/// Keeps trust decisions across launches, as JSON in the user's defaults.
/// Command lines are never saved: a trusted command is kept as its hash.
public struct SentinelTrustStore: Sendable {
    static let key = "Sentinel.trust.v2"
    /// Where earlier versions kept trusted paths.
    static let legacyKey = "Sentinel.trustedPaths"

    private let suiteName: String?

    /// `suiteName` nil is the app's standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    public static let standard = SentinelTrustStore()

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The saved entries. Paths trusted by an earlier version are carried
    /// over once: shells, interpreters and system tools are dropped (trusting
    /// one hid every later attack through it), the rest bind to the signature
    /// read the next time they run.
    public func load(now: Date = Date()) -> [SentinelTrustEntry] {
        let defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let entries = try? JSONDecoder().decode([SentinelTrustEntry].self, from: data) {
            return entries
        }
        guard let legacy = defaults.stringArray(forKey: Self.legacyKey) else { return [] }
        let entries = legacy.sorted().compactMap { path -> SentinelTrustEntry? in
            let name = (path as NSString).lastPathComponent
            guard path.hasPrefix("/"), !SentinelCatalog.isCommandRunner(name, path: path),
                  !SentinelCatalog.isSystemLocation(path) else { return nil }
            return SentinelTrustEntry(path: path, name: SentinelCatalog.appName(forPath: path) ?? name,
                                      anchor: .earlierVersion, added: now)
        }
        save(entries)
        defaults.removeObject(forKey: Self.legacyKey)
        return entries
    }

    public func save(_ entries: [SentinelTrustEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
