import XCTest
@testable import GhostProcessSniperCore

final class GPUClientMergeTests: XCTestCase {
    func testAServiceReachedThroughBothClassesIsCountedOnce() {
        let walk = [
            GPUClientUsage(serviceID: 7, clientID: 70, pid: 42, nanoseconds: 1_000),
            GPUClientUsage(serviceID: 7, clientID: 71, pid: 43, nanoseconds: 500)
        ]
        // AGXAccelerator subclasses IOAccelerator, so a naive walk visits it twice.
        XCTAssertEqual(IORegistryGPUClientReader.mergeClients(walk + walk), [42: 1_000, 43: 500])
    }

    func testSeparateClientsOfOneProcessAreSummed() {
        let clients = [
            GPUClientUsage(serviceID: 7, clientID: 70, pid: 42, nanoseconds: 1_000),
            GPUClientUsage(serviceID: 7, clientID: 72, pid: 42, nanoseconds: 250),
            GPUClientUsage(serviceID: 9, clientID: 90, pid: 42, nanoseconds: 50),
            GPUClientUsage(serviceID: 9, clientID: 91, pid: 44, nanoseconds: 0)
        ]
        XCTAssertEqual(IORegistryGPUClientReader.mergeClients(clients), [42: 1_300])
    }
}
