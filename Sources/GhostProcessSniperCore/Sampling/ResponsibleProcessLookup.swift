import Darwin
import Foundation

/// Asks macOS which process is responsible for another: the app behind an XPC
/// service, such as Safari for its `com.apple.WebKit.WebContent` tabs. It is the
/// attribution Activity Monitor uses. Looked up once per identity, and only for
/// processes launchd started outside any app bundle, where the process tree
/// alone cannot name the app.
struct ResponsibleProcessLookup: Sendable {
    typealias Query = @Sendable (Int32) -> Int32?

    private let query: Query
    private var cache: [ProcessIdentity: Int32] = [:]
    private var lastPrune: Date?

    init(query: @escaping Query = ResponsibleProcessLookup.system) {
        self.query = query
    }

    /// Responsible pids that differ from the process itself, keyed by identity.
    mutating func hints(for processes: [ProcessMetrics], now: Date) -> [ProcessIdentity: Int32] {
        var hints: [ProcessIdentity: Int32] = [:]
        for process in processes where process.parentPID <= 1 && !process.isSystemProcess
            && ThermalWorkloadResolver.applicationPath(process.executablePath) == nil {
            let responsible: Int32
            if let cached = cache[process.identity] {
                responsible = cached
            } else {
                responsible = query(process.pid) ?? process.pid
                cache[process.identity] = responsible
            }
            if responsible != process.pid, responsible > 1 { hints[process.identity] = responsible }
        }
        if lastPrune.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            let live = Set(processes.map(\.identity))
            cache = cache.filter { live.contains($0.key) }
            lastPrune = now
        }
        return hints
    }

    private typealias Function = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is exported by libSystem
    /// but not declared in the SDK; resolved once, and absent means no hints.
    private static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static let system: Query = { pid in
        guard let function else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }
}
