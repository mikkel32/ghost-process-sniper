import Darwin
import XCTest
@testable import GhostProcessSniperCore

/// Uses a loopback connection inside this test process; no network access.
final class RemoteConnectionReaderTests: XCTestCase {
    func testEstablishedConnectionIsReportedWithItsPort() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listener, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let accepted = Darwin.accept(listener, nil, nil)
        defer { close(accepted) }

        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(RemoteConnectionReader.connections(pid: pid, includeLoopback: true).contains("127.0.0.1:\(port)"))
        XCTAssertFalse(RemoteConnectionReader.connections(pid: pid).contains("127.0.0.1:\(port)"),
                       "loopback is not evidence of talking to another computer")
    }
}
