import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class KillLaunchAgentIndexTests: XCTestCase {
    private var folder: LaunchAgentsFolder!

    override func setUp() {
        folder = LaunchAgentsFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    func testReadsLabelKeepAliveAndRunAtLoad() {
        folder.write(label: "homebrew.mxcl.redis", program: ["/opt/homebrew/opt/redis/bin/redis-server"], keepAlive: true, runAtLoad: true)
        folder.write(label: "homebrew.mxcl.postgresql@16", program: ["/opt/homebrew/opt/postgresql@16/bin/postgres"],
                     keepAlive: ["SuccessfulExit": false])
        folder.write(label: "com.example.backup", program: ["/usr/local/bin/backup"], keepAlive: false)
        folder.write(label: "com.example.once", program: ["/usr/local/bin/once"])
        let index = folder.index()

        XCTAssertEqual(index.agent(label: "homebrew.mxcl.redis")?.keepAlive, true)
        XCTAssertEqual(index.agent(label: "homebrew.mxcl.redis")?.runAtLoad, true)
        XCTAssertEqual(index.agent(label: "homebrew.mxcl.postgresql@16")?.keepAlive, true, "a KeepAlive dictionary keeps it alive")
        XCTAssertEqual(index.agent(label: "com.example.backup")?.keepAlive, false)
        XCTAssertEqual(index.agent(label: "com.example.once")?.keepAlive, false)
        XCTAssertEqual(index.agent(label: "com.example.once")?.isDaemon, false)
        XCTAssertNil(index.agent(label: "com.example.missing"))
    }

    func testSymlinkedProgramResolvesToTheProcessExecutable() {
        let postgres = folder.linkedExecutable(named: "postgres")
        let plist = folder.write(label: "homebrew.mxcl.postgresql@16", program: [postgres.link, "-D", "/opt/homebrew/var/postgresql@16"],
                                 keepAlive: true)

        let agent = folder.index().agent(forExecutable: postgres.real)

        XCTAssertEqual(agent?.label, "homebrew.mxcl.postgresql@16")
        XCTAssertEqual(agent?.plistPath, plist)
        XCTAssertEqual(folder.index().agent(forExecutable: postgres.link)?.label, "homebrew.mxcl.postgresql@16",
                       "the link itself resolves too")
    }

    func testGenericLaunchersAndSharedProgramsAreNotMatchedByPath() {
        folder.write(label: "com.example.shell", program: ["/bin/sh", "-c", "exec /usr/local/bin/sync"], keepAlive: true)
        folder.write(label: "com.example.one", program: ["/usr/local/bin/worker", "--one"], keepAlive: true)
        folder.write(label: "com.example.two", program: ["/usr/local/bin/worker", "--two"], keepAlive: true)
        let index = folder.index()

        XCTAssertNil(index.agent(forExecutable: "/bin/sh"), "a shell says nothing about the job it runs")
        XCTAssertNil(index.agent(forExecutable: "/usr/local/bin/worker"), "two jobs run it; neither can be blamed")
        XCTAssertNotNil(index.agent(label: "com.example.one"))
    }

    func testDaemonFoldersMarkSystemJobs() {
        folder.write(label: "homebrew.mxcl.nginx", program: ["/opt/homebrew/opt/nginx/bin/nginx"], keepAlive: true)
        XCTAssertEqual(folder.index(isDaemon: true).agent(label: "homebrew.mxcl.nginx")?.isDaemon, true)
    }

    func testIndexNoticesPlistsAddedAfterTheFirstLookup() {
        let index = folder.index()
        XCTAssertNil(index.agent(label: "homebrew.mxcl.ollama"))

        folder.write(label: "homebrew.mxcl.ollama", program: ["/opt/homebrew/opt/ollama/bin/ollama", "serve"], keepAlive: true)

        XCTAssertEqual(index.agent(label: "homebrew.mxcl.ollama")?.keepAlive, true)
    }

    func testMalformedPlistsAreSkipped() {
        FileManager.default.createFile(atPath: folder.path + "/broken.plist", contents: Data("not a plist".utf8))
        folder.write(label: "com.example.fine", program: ["/usr/local/bin/fine"])
        let index = folder.index()

        XCTAssertNotNil(index.agent(label: "com.example.fine"))
        XCTAssertNil(index.agent(forExecutable: "relative/path"))
    }
}
