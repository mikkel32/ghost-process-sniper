import Darwin
import Foundation

struct TelemetryJob: Sendable {
    let pid: pid_t
    let identity: ProcessIdentity
    let sampleIndex: Int
    let userID: UInt32
    let kernelName: String
    /// 3 is an exec'd identity, 2 explicit demand, 1 a developer hint, 0 discovery.
    let priorityRank: Int
    /// Nothing has been read for this identity yet, not even its path.
    var needsPath: Bool
    /// argv has never been read, as opposed to a refresh of an old entry.
    let neverRead: Bool
    let refreshedAt: Date
    var executablePath: String
}

struct ForensicsJob: Sendable {
    let pid: pid_t
    let identity: ProcessIdentity
    let sampleIndex: Int
    let neverRead: Bool
    let refreshedAt: Date
}

struct TelemetryResult: Sendable {
    let job: TelemetryJob
    let entry: ProcessTelemetryCache.Entry
}

struct ForensicsResult: Sendable {
    let job: ForensicsJob
    let forensics: ProcessForensics
    let expensiveCallCount: Int
}

/// The pure parts of the telemetry and forensics lanes, run on the sampler
/// actor or fanned out across a task group when someone is watching.
enum SamplerJobs {
    /// Exec'd identities first, then demand, then never-read before stale, oldest first.
    static func argumentOrder(_ lhs: TelemetryJob, _ rhs: TelemetryJob) -> Bool {
        if lhs.priorityRank != rhs.priorityRank { return lhs.priorityRank > rhs.priorityRank }
        if lhs.neverRead != rhs.neverRead { return lhs.neverRead }
        return lhs.refreshedAt < rhs.refreshedAt
    }

    /// Never-read processes first, then the oldest reads.
    static func forensicsOrder(_ lhs: ForensicsJob, _ rhs: ForensicsJob) -> Bool {
        if lhs.neverRead != rhs.neverRead { return lhs.neverRead }
        return lhs.refreshedAt < rhs.refreshedAt
    }

    static func entry(for job: TelemetryJob, path: String, arguments: String?, argumentsRead: Bool,
                      now: Date) -> ProcessTelemetryCache.Entry {
        let name = job.kernelName.ifNotEmpty
            ?? URL(fileURLWithPath: path).lastPathComponent.ifNotEmpty
            ?? "pid-\(job.pid)"
        return ProcessTelemetryCache.Entry(
            name: name,
            executablePath: path,
            commandLine: arguments ?? path.ifNotEmpty ?? name,
            ownerName: UserNameResolver.name(for: job.userID),
            refreshedAt: now,
            argumentsRead: argumentsRead,
            kernelName: job.kernelName
        )
    }

    static func readArguments(_ job: TelemetryJob, source: any ProcessProbeSource, now: Date) -> TelemetryResult {
        let path = job.needsPath ? source.executablePath(job.pid) : job.executablePath
        let arguments = source.commandLine(job.pid)
        return TelemetryResult(job: job, entry: entry(for: job, path: path, arguments: arguments,
                                                      argumentsRead: true, now: now))
    }

    static func readArguments(_ jobs: ArraySlice<TelemetryJob>, source: any ProcessProbeSource,
                              now: Date) async -> [TelemetryResult] {
        await withTaskGroup(of: TelemetryResult.self) { group in
            for job in jobs {
                group.addTask { readArguments(job, source: source, now: now) }
            }
            var results: [TelemetryResult] = []
            results.reserveCapacity(jobs.count)
            for await result in group { results.append(result) }
            return results
        }
    }

    static func readForensics(_ job: ForensicsJob, source: any ProcessProbeSource) -> ForensicsResult {
        let read = source.forensics(job.pid)
        return ForensicsResult(job: job, forensics: read.forensics, expensiveCallCount: read.expensiveCallCount)
    }

    static func readForensics(_ jobs: ArraySlice<ForensicsJob>, source: any ProcessProbeSource) async -> [ForensicsResult] {
        await withTaskGroup(of: ForensicsResult.self) { group in
            for job in jobs {
                group.addTask { readForensics(job, source: source) }
            }
            var results: [ForensicsResult] = []
            results.reserveCapacity(jobs.count)
            for await result in group { results.append(result) }
            return results
        }
    }
}
