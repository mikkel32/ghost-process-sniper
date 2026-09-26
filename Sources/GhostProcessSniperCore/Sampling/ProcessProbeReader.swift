import Darwin
import Foundation

/// Reads the cheap identity graph before spending the bounded enrichment budget.
enum ProcessProbeReader {
    private static let developerNames: Set<String> = [
        "node", "npm", "pnpm", "yarn", "bun", "vite", "deno", "python", "python3",
        "ruby", "rails", "java", "gradle", "mvn", "docker", "com.docker.backend",
        "colima", "ollama", "swift", "swift-frontend", "swift-build", "xcodebuild",
        "electron", "uvicorn", "gunicorn", "webpack", "next"
    ]

    static func read(_ pids: [pid_t], startIndex: Int, endIndex: Int,
                     plan: SamplingPlan, deadline: SamplerDeadline, pass: UInt64, budget: Int) -> ParallelProbeResult {
        var samples: [RawProcessSample] = []
        var priorities: [Int] = []
        samples.reserveCapacity(max(0, endIndex - startIndex))
        priorities.reserveCapacity(max(0, endIndex - startIndex))
        var skipped = 0
        var expired = false
        var taskReads = 0
        var expensiveCalls = 0

        for index in startIndex..<endIndex {
            if deadline.isExpired() {
                expired = true
                skipped += endIndex - index
                break
            }
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let identity = ProcessIdentity(pid: Int32(pid), startTimeSeconds: info.pbi_start_tvsec,
                startTimeMicroseconds: info.pbi_start_tvusec)
            let name = processName(info, pid: pid)
            let requested = plan.candidateSet.contains(identity: identity, pid: Int32(pid)) ||
                plan.includeForensicsFor.contains(identity) || plan.includeForensicsForPIDs.contains(Int32(pid)) ||
                plan.probePolicy.richMetricIdentities.contains(identity) || plan.probePolicy.richMetricPIDs.contains(Int32(pid))
            let hinted = isDeveloperName(name)
            let lite = ProcessLiteRecord(identity: identity, parentPID: Int32(info.pbi_ppid),
                userID: info.pbi_uid, name: name, processGroupID: Int32(info.pbi_pgid), status: info.pbi_status,
                flags: info.pbi_flags, openFileCount: Int(info.pbi_nfiles), sampledAt: plan.sampledAt)
            priorities.append(requested ? 2 : hinted ? 1 : 0)
            samples.append(RawProcessSample(pid: pid, liteRecord: lite, taskInfo: nil, usage: nil,
                preliminaryPriority: requested || hinted))
        }

        let selected = RichProbeSelector.indices(priorities: priorities,
            budget: plan.probePolicy.allowsRichMetrics ? budget : 0, pass: pass)
        for index in selected {
            if deadline.isExpired() {
                expired = true
                break
            }
            let sample = samples[index]
            var task = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.stride)
            expensiveCalls += 1
            guard proc_pidinfo(sample.pid, PROC_PIDTASKALLINFO, 0, &task, size) == size,
                  task.pbsd.pbi_start_tvsec == sample.liteRecord.identity.startTimeSeconds,
                  task.pbsd.pbi_start_tvusec == sample.liteRecord.identity.startTimeMicroseconds else {
                // Keep the BSD record. A denied or raced task read is not a disappeared process.
                continue
            }
            taskReads += 1
            var usageInfo = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usageInfo) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(sample.pid, RUSAGE_INFO_V4, rebound)
                }
            }
            samples[index] = RawProcessSample(pid: sample.pid, liteRecord: sample.liteRecord,
                taskInfo: task, usage: result == 0 ? usageInfo : nil,
                preliminaryPriority: sample.preliminaryPriority)
        }
        return ParallelProbeResult(samples: samples, cheapMetricsCount: samples.count,
            richMetricsCount: taskReads, skippedCount: skipped, expensiveCallCount: expensiveCalls,
            bsdReadCount: samples.count, taskInfoReadCount: taskReads, didHitDeadline: expired)
    }

    private static func processName(_ info: proc_bsdinfo, pid: pid_t) -> String {
        var storage = info.pbi_name
        let capacity = MemoryLayout.size(ofValue: storage)
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { rebound in
                let name = String(cString: rebound)
                return name.isEmpty ? "pid-\(pid)" : name
            }
        }
    }

    private static func isDeveloperName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return developerNames.contains(lowered) || lowered.contains("electron") ||
            lowered.contains("vite") || lowered.contains("ollama") ||
            lowered.contains("llama") || lowered.contains("node")
    }
}
