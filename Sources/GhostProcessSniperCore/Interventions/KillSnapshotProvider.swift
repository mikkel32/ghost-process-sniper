import Darwin
import Foundation

public protocol KillSnapshotProviding: Sendable {
    func snapshot(request: KillSnapshotRequest) async throws -> KillProcessSnapshot
}

public extension KillSnapshotProviding {
    func snapshot(policy: KillSnapshotPolicy) async throws -> KillProcessSnapshot {
        try await snapshot(request: KillSnapshotRequest(policy: policy))
    }
}

public struct ProcessLookupKillSnapshotProvider: KillSnapshotProviding {
    private let lookup: ProcessLookup

    public init(lookup: ProcessLookup) {
        self.lookup = lookup
    }

    public func snapshot(request: KillSnapshotRequest) async throws -> KillProcessSnapshot {
        let snapshot = try await lookup.killSnapshot(policy: request.policy)
        return KillProcessSnapshot(
            processes: snapshot.processes,
            sampledAt: snapshot.sampledAt,
            policy: request.policy,
            elapsedMilliseconds: snapshot.elapsedMilliseconds,
            usedCheapPath: snapshot.usedCheapPath,
            expensiveCallCount: snapshot.expensiveCallCount,
            request: request,
            graph: snapshot.graph,
            arena: snapshot.arena,
            graphReadCount: snapshot.graphReadCount,
            heavyMetricReadCount: snapshot.heavyMetricReadCount,
            didHitBudget: snapshot.didHitBudget,
            targetConversionCount: snapshot.targetConversionCount,
            skippedOptionalWorkCount: snapshot.skippedOptionalWorkCount
        )
    }
}

public actor NativeKillSnapshotProvider: KillSnapshotProviding {
    private var pidBuffer = [pid_t](repeating: 0, count: 4096)

    public init() {}

    public func snapshot(request: KillSnapshotRequest) async throws -> KillProcessSnapshot {
        if request.policy == .verify,
           request.verificationMode == .targetOnly,
           !request.requiresCompleteGraph,
           !request.targetIdentities.isEmpty {
            return targetOnlySnapshot(request: request)
        }

        let started = Date()
        let sampledAt = Date()
        let count = try listPIDCount()
        var liteProcesses: [KillProcessLite] = []
        liteProcesses.reserveCapacity(count)
        var graphReadCount = 0
        var didHitBudget = false

        for index in 0..<count {
            if Date().timeIntervalSince(started) * 1_000 > request.budget.targetMilliseconds {
                didHitBudget = true
            }
            let pid = pidBuffer[index]
            guard pid > 0 else {
                continue
            }

            var bsdInfo = proc_bsdinfo()
            let bsdInfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdInfoSize)
            guard result == bsdInfoSize else {
                continue
            }
            graphReadCount += 1

            let identity = ProcessIdentity(
                pid: Int32(pid),
                startTimeSeconds: bsdInfo.pbi_start_tvsec,
                startTimeMicroseconds: bsdInfo.pbi_start_tvusec
            )
            let name = processName(from: bsdInfo, pid: pid)

            liteProcesses.append(
                KillProcessLite(
                    identity: identity,
                    parentPID: Int32(bsdInfo.pbi_ppid),
                    userID: bsdInfo.pbi_uid,
                    ownerName: UserNameResolver.name(for: bsdInfo.pbi_uid),
                    name: name,
                    status: bsdInfo.pbi_status,
                    flags: bsdInfo.pbi_flags,
                    processGroupID: Int32(bsdInfo.pbi_pgid),
                    openFileCount: Int(bsdInfo.pbi_nfiles),
                    isSystemProcess: (bsdInfo.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0,
                    sampledAt: sampledAt
                )
            )
        }

        var arena = KillGraphArena(
            processes: liteProcesses,
            sampledAt: sampledAt,
            pidReadCount: graphReadCount
        )
        let heavyIdentities = heavyMetricIdentities(
            request: request,
            arena: arena
        )
        var heavyReadCount = 0
        if request.includeHeavyMetricsForTargets && !heavyIdentities.isEmpty {
            for index in liteProcesses.indices where heavyIdentities.contains(liteProcesses[index].identity) {
                guard heavyReadCount < request.budget.maxHeavyMetricReads else {
                    didHitBudget = true
                    break
                }
                guard let heavy = heavyMetrics(for: pid_t(liteProcesses[index].pid)) else {
                    continue
                }
                liteProcesses[index] = liteProcesses[index].updatingHeavyMetrics(
                    residentMemoryBytes: heavy.residentMemoryBytes,
                    physicalFootprintBytes: heavy.physicalFootprintBytes,
                    virtualMemoryBytes: heavy.virtualMemoryBytes,
                    totalProcessorSeconds: heavy.totalProcessorSeconds,
                    threadCount: heavy.threadCount,
                    isSystemProcess: heavy.isSystemProcess
                )
                heavyReadCount += 1
            }
        }
        if heavyReadCount > 0 {
            arena = arena.replacingProcesses(
                liteProcesses,
                patchedHeavyMetricCount: heavyReadCount
            )
        }

        let elapsed = Date().timeIntervalSince(started) * 1_000
        let graph = KillProcessGraph(
            processes: liteProcesses,
            sampledAt: sampledAt,
            elapsedMilliseconds: elapsed,
            graphReadCount: graphReadCount,
            heavyMetricReadCount: heavyReadCount,
            didHitBudget: didHitBudget || elapsed > request.budget.targetMilliseconds,
            usedBSDInfoPath: true
        )
        let convertedProcesses = convertedMetrics(
            request: request,
            graph: graph,
            arena: arena
        )

        return KillProcessSnapshot(
            processes: convertedProcesses,
            sampledAt: sampledAt,
            policy: request.policy,
            elapsedMilliseconds: elapsed,
            usedCheapPath: true,
            expensiveCallCount: heavyReadCount,
            request: request,
            graph: graph,
            arena: arena,
            graphReadCount: graphReadCount,
            heavyMetricReadCount: heavyReadCount,
            didHitBudget: graph.didHitBudget,
            targetConversionCount: convertedProcesses.count,
            skippedOptionalWorkCount: max(0, graphReadCount - convertedProcesses.count)
        )
    }

    private nonisolated func targetOnlySnapshot(request: KillSnapshotRequest) -> KillProcessSnapshot {
        let started = Date()
        let sampledAt = Date()
        var liteProcesses: [KillProcessLite] = []
        liteProcesses.reserveCapacity(request.targetIdentities.count)
        var graphReadCount = 0

        for identity in request.targetIdentities {
            var bsdInfo = proc_bsdinfo()
            let bsdInfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let result = proc_pidinfo(pid_t(identity.pid), PROC_PIDTBSDINFO, 0, &bsdInfo, bsdInfoSize)
            guard result == bsdInfoSize else {
                continue
            }
            graphReadCount += 1
            let liveIdentity = ProcessIdentity(
                pid: identity.pid,
                startTimeSeconds: bsdInfo.pbi_start_tvsec,
                startTimeMicroseconds: bsdInfo.pbi_start_tvusec
            )
            liteProcesses.append(
                KillProcessLite(
                    identity: liveIdentity,
                    parentPID: Int32(bsdInfo.pbi_ppid),
                    userID: bsdInfo.pbi_uid,
                    ownerName: UserNameResolver.name(for: bsdInfo.pbi_uid),
                    name: processName(from: bsdInfo, pid: pid_t(identity.pid)),
                    status: bsdInfo.pbi_status,
                    flags: bsdInfo.pbi_flags,
                    processGroupID: Int32(bsdInfo.pbi_pgid),
                    openFileCount: Int(bsdInfo.pbi_nfiles),
                    isSystemProcess: (bsdInfo.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0,
                    sampledAt: sampledAt
                )
            )
        }

        let arena = KillGraphArena(
            processes: liteProcesses,
            sampledAt: sampledAt,
            pidReadCount: graphReadCount
        )
        let elapsed = Date().timeIntervalSince(started) * 1_000
        let graph = KillProcessGraph(
            processes: liteProcesses,
            sampledAt: sampledAt,
            elapsedMilliseconds: elapsed,
            graphReadCount: graphReadCount,
            heavyMetricReadCount: 0,
            didHitBudget: elapsed > request.budget.targetMilliseconds,
            usedBSDInfoPath: true
        )
        let converted = liteProcesses
            .prefix(request.conversionBudget.maxConvertedProcesses)
            .map { $0.asProcessMetrics() }

        return KillProcessSnapshot(
            processes: converted,
            sampledAt: sampledAt,
            policy: request.policy,
            elapsedMilliseconds: elapsed,
            usedCheapPath: true,
            expensiveCallCount: 0,
            request: request,
            graph: graph,
            arena: arena,
            graphReadCount: graphReadCount,
            heavyMetricReadCount: 0,
            didHitBudget: graph.didHitBudget,
            targetConversionCount: converted.count,
            skippedOptionalWorkCount: 0
        )
    }

    private func listPIDCount() throws -> Int {
        var bytesWritten = 0
        while true {
            let bufferSize = pidBuffer.count * MemoryLayout<pid_t>.stride
            bytesWritten = Int(pidBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(bufferSize))
            })
            if bytesWritten < bufferSize || pidBuffer.count >= 65_536 {
                break
            }
            pidBuffer.append(contentsOf: repeatElement(0, count: pidBuffer.count))
        }
        guard bytesWritten > 0 else {
            throw ProcessSamplerError.listFailed
        }
        return Int(bytesWritten) / MemoryLayout<pid_t>.stride
    }

    private nonisolated func processName(from info: proc_bsdinfo, pid: pid_t) -> String {
        var nameStorage = info.pbi_name
        let capacity = MemoryLayout.size(ofValue: nameStorage)
        return withUnsafePointer(to: &nameStorage) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { rebound in
                let name = String(cString: rebound)
                if !name.isEmpty {
                    return name
                }
                return "pid-\(pid)"
            }
        }
    }

    private nonisolated func heavyMetricIdentities(
        request: KillSnapshotRequest,
        arena: KillGraphArena
    ) -> Set<ProcessIdentity> {
        var output = Set(request.targetIdentities)
        if let root = request.rootIdentity {
            switch request.scope {
            case .ownedFamily, .ownedProcessGroupPreview:
                output.formUnion(arena.descendants(of: root).map { $0.process.identity })
            case .singleRoot:
                output.insert(root)
            }
        }
        return output
    }

    private nonisolated func convertedMetrics(
        request: KillSnapshotRequest,
        graph: KillProcessGraph,
        arena: KillGraphArena
    ) -> [ProcessMetrics] {
        guard request.rootIdentity != nil else {
            return Array(graph.processes.prefix(request.conversionBudget.maxConvertedProcesses)).map { $0.asProcessMetrics() }
        }

        var identities = arena.conversionIdentities(
            plan: KillPlan(
                rootIdentity: request.rootIdentity ?? ProcessIdentity(pid: 0, startTimeSeconds: 0, startTimeMicroseconds: 0),
                targetIdentities: request.targetIdentities,
                protectedPIDs: request.protectedPIDs,
                displayName: "kill snapshot",
                scope: request.scope
            ),
            currentUserID: UInt32(geteuid())
        )
        identities.formUnion(request.protectedPIDs.compactMap { pid in
            arena.processes(for: pid).first?.identity
        })

        return arena.processes
            .filter { identities.contains($0.identity) || request.protectedPIDs.contains($0.pid) }
            .prefix(request.conversionBudget.maxConvertedProcesses)
            .map { $0.asProcessMetrics() }
    }

    private struct HeavyMetrics {
        let residentMemoryBytes: UInt64
        let physicalFootprintBytes: UInt64
        let virtualMemoryBytes: UInt64
        let totalProcessorSeconds: TimeInterval
        let threadCount: Int
        let isSystemProcess: Bool
    }

    private nonisolated func heavyMetrics(for pid: pid_t) -> HeavyMetrics? {
        var taskInfo = proc_taskallinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskallinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &taskInfo, taskInfoSize)
        guard result == taskInfoSize else {
            return nil
        }
        return HeavyMetrics(
            residentMemoryBytes: taskInfo.ptinfo.pti_resident_size,
            physicalFootprintBytes: taskInfo.ptinfo.pti_resident_size,
            virtualMemoryBytes: taskInfo.ptinfo.pti_virtual_size,
            totalProcessorSeconds: TimeInterval(taskInfo.ptinfo.pti_total_user + taskInfo.ptinfo.pti_total_system) / 1_000_000_000,
            threadCount: Int(taskInfo.ptinfo.pti_threadnum),
            isSystemProcess: (taskInfo.pbsd.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0
        )
    }
}
