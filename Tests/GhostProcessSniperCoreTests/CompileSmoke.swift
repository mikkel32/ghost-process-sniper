#if canImport(XCTest)
import XCTest
import GhostProcessSniperCore

final class GhostProcessSniperCoreTests: XCTestCase {
    func testCompileSmoke() {
        ghostProcessSniperCoreCompileSmoke()
    }
}
#endif

import GhostProcessSniperCore

func ghostProcessSniperCoreCompileSmoke() {
    _ = ThresholdSettings.aggressive
    _ = DevProcessClassifier()
    _ = CPUUsageTracker<ProcessIdentity>()
    _ = NativeProcessSampler()
    _ = ProcessFamilyBuilder()
    _ = RadarIntelligence()
    _ = RadarRuleEngine()
    _ = RadarScheduler()
    _ = RadarPipeline()
    _ = RadarPerformanceMetrics.empty
    _ = SamplingPlan.balanced()
    _ = ProcessSignature(displayName: "node", canonicalPath: "/usr/local/bin/node", commandLine: "node server.js")
    _ = GhostScoreComponent(kind: .memory, title: "memory", detail: "memory", impact: 1, level: .watch)
    _ = FamilyTriageViewModel.filtered(families: [], query: "", filter: .all, sort: .smart)
}
