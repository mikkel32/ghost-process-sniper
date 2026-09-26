import XCTest
@testable import GhostProcessSniperCore

final class ForensicsRefreshTests: XCTestCase {
    private let tcpEstablished: Int32 = 4

    func testOnlyListeningTCPSocketsCountAsPorts() {
        let port3000 = Int32(UInt16(3000).bigEndian)
        XCTAssertEqual(ListeningSocketReader.listeningPort(kind: Int32(SOCKINFO_TCP), tcpState: Int32(TSI_S_LISTEN),
                                                           localPort: port3000), 3000)
        XCTAssertNil(ListeningSocketReader.listeningPort(kind: Int32(SOCKINFO_TCP), tcpState: tcpEstablished,
                                                         localPort: Int32(UInt16(53_211).bigEndian)))
        XCTAssertNil(ListeningSocketReader.listeningPort(kind: Int32(SOCKINFO_IN), tcpState: Int32(TSI_S_LISTEN),
                                                         localPort: Int32(UInt16(5353).bigEndian)))
        XCTAssertNil(ListeningSocketReader.listeningPort(kind: Int32(SOCKINFO_TCP), tcpState: Int32(TSI_S_LISTEN),
                                                         localPort: 0))
    }

    func testStaleForensicsAreServedAndRevalidated() async throws {
        let source = FakeProbeSource.table(count: 10)
        let sampler = NativeProcessSampler(source: source)
        let focused: Int32 = 1_002
        _ = try await sampler.sample(plan: plan(at: 0, focusing: focused, maxForensics: 4))
        XCTAssertEqual(source.recordedCalls.forensics, 1)

        // A dev server that bound its port after the first read.
        source.update(pid: focused) { $0.ports = [3000] }
        let starved = try await sampler.sample(plan: plan(at: 61, focusing: focused, maxForensics: 0))
        let served = try XCTUnwrap(starved.processes.first { $0.pid == focused })
        XCTAssertFalse(served.forensics.isPartial, "the stale read is served, not 'deferred'")
        XCTAssertEqual(served.forensics.currentDirectory, "/work")
        XCTAssertEqual(source.recordedCalls.forensics, 1)

        let refreshed = try await sampler.sample(plan: plan(at: 62, focusing: focused, maxForensics: 4))
        XCTAssertEqual(source.recordedCalls.forensics, 2)
        XCTAssertEqual(refreshed.processes.first { $0.pid == focused }?.forensics.listeningPorts, [3000])
    }

    func testFreshForensicsAreNotReread() async throws {
        let source = FakeProbeSource.table(count: 4)
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: plan(at: 0, focusing: 1_001, maxForensics: 4))
        _ = try await sampler.sample(plan: plan(at: 59, focusing: 1_001, maxForensics: 4))
        XCTAssertEqual(source.recordedCalls.forensics, 1)
    }

    func testQuietProcessKeepsItsLastKnownPorts() async throws {
        let source = FakeProbeSource.table(count: 4)
        source.update(pid: 1_001) { $0.ports = [5173] }
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: plan(at: 0, focusing: 1_001, maxForensics: 4))
        let quiet = try await sampler.sample(plan: .fixture(at: 120))
        XCTAssertEqual(quiet.processes.first { $0.pid == 1_001 }?.forensics.listeningPorts, [5173])
        let expired = try await sampler.sample(plan: .fixture(at: 700))
        XCTAssertEqual(expired.processes.first { $0.pid == 1_001 }?.forensics.listeningPorts, [])
    }

    func testNeverReadProcessesGoFirstWithinTheForensicsCap() async throws {
        let source = FakeProbeSource.table(count: 3)
        let sampler = NativeProcessSampler(source: source)
        _ = try await sampler.sample(plan: plan(at: 0, focusing: 1_000, maxForensics: 1))
        let second = try await sampler.sample(plan: .fixture(at: 90) {
            $0.includeForensicsForPIDs = [1_000, 1_001]
            $0.maxForensicsPerRefresh = 1
        })
        XCTAssertEqual(second.processes.first { $0.pid == 1_001 }?.forensics.currentDirectory, "/work")
        XCTAssertEqual(source.recordedCalls.forensics, 2)
    }

    private func plan(at second: Double, focusing pid: Int32, maxForensics: Int) -> SamplingPlan {
        .fixture(at: second) {
            $0.includeForensicsForPIDs = [pid]
            $0.maxForensicsPerRefresh = maxForensics
        }
    }
}
