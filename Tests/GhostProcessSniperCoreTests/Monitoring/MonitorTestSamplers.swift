import Foundation
@testable import GhostProcessSniperCore

/// Counts calls and can hold chosen calls until released, so a test can
/// overlap refreshes deterministically.
actor GatedSampler: ProcessSampling {
    private let processes: [ProcessMetrics]
    private let heldCalls: Set<Int>
    private let yieldsPerCall: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var running = 0
    private(set) var calls = 0
    private(set) var plans: [SamplingPlan] = []
    /// The most samples ever in progress at once; the monitor must keep it at 1.
    private(set) var maxConcurrent = 0

    /// `yieldsPerCall` suspends each call a few times, so a second sample
    /// started by mistake would overlap it.
    init(processes: [ProcessMetrics] = [], holding heldCalls: Set<Int> = [], yieldsPerCall: Int = 0) {
        self.processes = processes
        self.heldCalls = heldCalls
        self.yieldsPerCall = yieldsPerCall
    }

    var waitingCount: Int { waiting.count }

    func sample(plan: SamplingPlan) async throws -> ProcessSampleBatch {
        calls += 1
        plans.append(plan)
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        defer { running -= 1 }
        if heldCalls.contains(calls) {
            await withCheckedContinuation { waiting.append($0) }
        }
        for _ in 0..<yieldsPerCall {
            await Task.yield()
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
