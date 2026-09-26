import Darwin
import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// The native sampler's listening-port reads against a real loopback
/// socket. They need libproc, so they only assert on macOS.
final class NativeListeningPortTests: XCTestCase {
    func testForensicsListOnlyListeningPorts() async throws {
        #if os(macOS)
        try await withLoopbackConnection { listenerPort, clientPort in
            var plan = SamplingPlan.balanced(now: Date(timeIntervalSince1970: 1_020))
            plan.includeForensicsForPIDs = [getpid()]
            let batch = try await NativeProcessSampler().sample(plan: plan)
            let current = try XCTUnwrap(batch.processes.first { $0.pid == getpid() }, "the sampler lists the test process")
            XCTAssertTrue(current.forensics.listeningPorts.contains(listenerPort), "the test's TCP listener")
            XCTAssertFalse(current.forensics.listeningPorts.contains(clientPort), "not an outbound connection's ephemeral port")
        }
        #endif
    }

    func testPortCensusFindsAQuietListener() async throws {
        #if os(macOS)
        try await withLoopbackConnection { listenerPort, _ in
            var plan = SamplingPlan.balanced(now: Date(timeIntervalSince1970: 1_030))
            plan.portCensusAll = true
            let batch = try await NativeProcessSampler().sample(plan: plan)
            let current = try XCTUnwrap(batch.processes.first { $0.pid == getpid() }, "the sampler lists the test process")
            XCTAssertGreaterThan(batch.stats.portCensusCount, 0, "an explicit census reads ports")
            XCTAssertTrue(current.forensics.listeningPorts.contains(listenerPort))
        }
        #endif
    }

    #if os(macOS)
    private struct SocketFailure: Error {
        let call: String
    }

    /// A loopback listener plus one outbound connection to it, both held open while `body` runs.
    private func withLoopbackConnection(_ body: (_ listenerPort: Int, _ clientPort: Int) async throws -> Void) async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SocketFailure(call: "socket") }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw SocketFailure(call: "listen") }
        let listenerPort = try boundPort(listener)

        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw SocketFailure(call: "client socket") }
        defer { close(client) }
        address.sin_port = in_port_t(UInt16(listenerPort).bigEndian)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
        }
        guard connected == 0 else { throw SocketFailure(call: "connect") }
        let accepted = accept(listener, nil, nil)
        defer { if accepted >= 0 { close(accepted) } }
        try await body(listenerPort, try boundPort(client))
    }

    private func boundPort(_ descriptor: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw SocketFailure(call: "getsockname") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    #endif
}
