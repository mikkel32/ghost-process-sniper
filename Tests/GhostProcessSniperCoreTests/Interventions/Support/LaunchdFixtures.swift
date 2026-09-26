import Foundation
@testable import GhostProcessSniperCore

/// Answers launchctl commands from a script and records every call.
final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private let listing: (status: Int32, stdout: String)
    private let bootoutStatus: Int32
    private let onBootout: (@Sendable () -> Void)?

    init(list: String = "PID\tStatus\tLabel\n", listStatus: Int32 = 0, bootoutStatus: Int32 = 0,
         onBootout: (@Sendable () -> Void)? = nil) {
        listing = (listStatus, list)
        self.bootoutStatus = bootoutStatus
        self.onBootout = onBootout
    }

    var invocations: [[String]] { lock.withLock { calls } }

    func run(_ args: [String], timeout: Duration) async -> (status: Int32, stdout: String) {
        lock.withLock { calls.append(args) }
        switch args.first {
        case "list":
            return listing
        case "bootout":
            if bootoutStatus == 0 { onBootout?() }
            return (bootoutStatus, "")
        default:
            return (0, "")
        }
    }
}

/// A temporary LaunchAgents folder of real plists.
final class LaunchAgentsFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gps-agents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path }

    func index(isDaemon: Bool = false) -> KillLaunchAgentIndex {
        KillLaunchAgentIndex(directories: [KillLaunchAgentIndex.Directory(path: path, isDaemon: isDaemon)])
    }

    @discardableResult
    func write(label: String, program: [String], keepAlive: Any? = nil, runAtLoad: Bool? = nil, exitTimeOut: Int? = nil,
               file: String? = nil) -> String {
        var plist: [String: Any] = ["Label": label, "ProgramArguments": program]
        if let keepAlive { plist["KeepAlive"] = keepAlive }
        if let runAtLoad { plist["RunAtLoad"] = runAtLoad }
        if let exitTimeOut { plist["ExitTimeOut"] = exitTimeOut }
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let target = url.appendingPathComponent(file ?? "\(label).plist")
        try! data.write(to: target)
        return target.path
    }

    /// An executable and a symlink to it, like /opt/homebrew/opt/<formula>
    /// pointing into the Cellar.
    func linkedExecutable(named name: String) -> (real: String, link: String) {
        let cellar = url.appendingPathComponent("Cellar/bin")
        let opt = url.appendingPathComponent("opt")
        try? FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: opt, withIntermediateDirectories: true)
        let real = cellar.appendingPathComponent(name)
        FileManager.default.createFile(atPath: real.path, contents: Data("#!/bin/sh\n".utf8))
        let link = opt.appendingPathComponent(name)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (KillLaunchAgentIndex.canonicalPath(real.path), link.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
