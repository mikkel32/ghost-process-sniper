import Foundation
@testable import GhostProcessSniperCore

/// Counts calls and can hold chosen calls until released, so a test can
/// overlap refreshes deterministically.
actor GatedSampler: ProcessSampling {
    private let processes: [ProcessMetrics]
    private let heldCalls: Set<Int>
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    private(set) var plans: [SamplingPlan] = []

    init(processes: [ProcessMetrics] = [], holding heldCalls: Set<Int> = []) {
        self.processes = processes
        self.heldCalls = heldCalls
    }

    var waitingCount: Int { waiting.count }

    func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch {
        calls += 1
        plans.append(plan)
        if heldCalls.contains(calls) {
            await withCheckedContinuation { waiting.append($0) }
        }
        return ProcessSampleBatch(processes: processes, sampledAt: plan.sampledAt, stats: .empty)
    }

    func release() {
        let released = waiting
        waiting = []
        released.forEach { $0.resume() }
    }
}

/// Polls a main-actor condition, yielding to the refresh tasks under test.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
