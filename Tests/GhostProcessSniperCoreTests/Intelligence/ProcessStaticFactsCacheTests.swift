import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ProcessStaticFactsCacheTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    func testReusesFactsUntilTheProcessExecs() {
        let cache = ProcessStaticFactsCache()
        var built = 0
        let make: (ProcessMetrics) -> ProcessStaticFacts = { process in
            built += 1
            return Self.facts(for: process)
        }
        let shell = Fixture.process(pid: 700, name: "zsh", path: "/bin/zsh", command: "-zsh")
        _ = cache.facts(for: [shell], make: make)
        _ = cache.facts(for: [shell], make: make)
        XCTAssertEqual(built, 1)

        // exec keeps the pid and start time but swaps the image.
        let execd = Fixture.process(pid: 700, name: "node", path: "/usr/local/bin/node", command: "node server.js")
        let facts = cache.facts(for: [execd], make: make)
        XCTAssertEqual(built, 2)
        XCTAssertEqual(facts.first?.signature.displayName, "node")
    }

    func testDropsIdentitiesUnseenForTwoPruneCycles() {
        let cache = ProcessStaticFactsCache()
        let gone = Fixture.process(pid: 701)
        let live = Fixture.process(pid: 702)
        _ = cache.facts(for: [gone, live], make: Self.facts)
        for _ in 0..<(Int(ProcessStaticFactsCache.pruneInterval) * 3) {
            _ = cache.facts(for: [live], make: Self.facts)
        }
        XCTAssertEqual(cache.count, 1)
    }

    func testParentDirectoryIsPlainStringWork() {
        XCTAssertEqual(ProcessStaticFacts.parentDirectory(of: "/usr/local/bin/node"), "/usr/local/bin")
        XCTAssertEqual(ProcessStaticFacts.parentDirectory(of: "/launchd"), "/")
        // No path means no neighborhood: unreadable processes must not group.
        XCTAssertEqual(ProcessStaticFacts.parentDirectory(of: ""), "")
        XCTAssertEqual(ProcessStaticFacts.parentDirectory(of: "node"), "")
        XCTAssertEqual(ProcessStaticFacts.appBundlePrefix(of: "/Applications/Foo.APP/Contents/MacOS/Foo"), "/applications/foo.app/")
    }

    private static func facts(for process: ProcessMetrics) -> ProcessStaticFacts {
        ProcessStaticFacts(
            classification: DevProcessClassifier().classification(for: process),
            signature: ProcessSignature.from(root: process),
            commandHint: nil,
            appBundlePrefix: nil,
            parentDirectory: ProcessStaticFacts.parentDirectory(of: process.executablePath),
            isHelperNamed: false,
            isAppMainBinary: false,
            isLaunchdManaged: false,
            isHardwareEligible: true,
            duplicateKey: nil
        )
    }
}
