import Foundation
@testable import GhostProcessSniperCore

extension FakeProcessTable {
    /// Seconds the virtual clock has moved: the sum of every sleeper request.
    var elapsedSeconds: TimeInterval {
        now().timeIntervalSince(Date(timeIntervalSince1970: 1_000_000))
    }

    func killer(sleeper: (@Sendable (UInt64) async -> Void)? = nil) -> ProcessKiller {
        ProcessKiller(snapshotProvider: self, signaler: self, currentUserID: 501, sleeper: sleeper ?? self.sleeper)
    }
}

extension KillPlan {
    /// A plan over `members` whose workload carries the paths and command
    /// lines the risk assessor classifies.
    static func fixture(
        _ root: KillProcessLite,
        members: [KillProcessLite]? = nil,
        paths: [Int32: String] = [:],
        commands: [Int32: String] = [:]
    ) -> KillPlan {
        let members = members ?? [root]
        let workload = KillWorkloadProfile(
            processes: members.map {
                KillWorkloadProcess(pid: $0.pid, parentPID: $0.parentPID, name: $0.name, executablePath: paths[$0.pid] ?? "",
                                    commandLine: commands[$0.pid] ?? paths[$0.pid] ?? $0.name,
                                    isRoot: $0.identity == root.identity)
            },
            ancestors: [],
            parentIsLaunchd: root.parentPID == 1
        )
        return KillPlan(rootIdentity: root.identity, targetIdentities: members.map(\.identity), protectedPIDs: [],
                        displayName: root.name, workload: workload)
    }
}

enum KillFixture {
    static let pagesPath = "/Applications/Pages.app/Contents/MacOS/Pages"
    static let pagesHelperPath = "/Applications/Pages.app/Contents/XPCServices/Pages Helper.xpc/Contents/MacOS/Pages Helper"
    static let postgresCommand = "/opt/homebrew/bin/postgres -D /opt/homebrew/var/postgres"
    static let viteCommand = "node /work/app/node_modules/.bin/vite"
}
