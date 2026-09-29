import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ThermalWorkloadResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_200_000)
    private let xcode = "/Applications/Xcode.app"
    private var toolchain: String { "\(xcode)/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin" }

    func testBuildChildrenCollapseIntoOneJobNamedAfterItsRoot() throws {
        let processes = terminalShell() + [process(603, parent: 602, name: "make", path: "/usr/bin/make", cpu: 1)] +
            (0..<10).map { process(Int32(610 + $0), parent: 603, name: "clang", path: "/usr/bin/clang", cpu: 95) }
        let result = projection(processes)
        let job = try XCTUnwrap(result.contributors.first)
        XCTAssertEqual(result.contributors.count, 1)
        XCTAssertEqual(job.displayName, "make")
        XCTAssertEqual(job.kind, .job)
        XCTAssertEqual(job.hostAppName, "Terminal")
        XCTAssertEqual(job.processCount, 11)
        XCTAssertEqual(job.cpuCapacityPercent, 95.1, accuracy: 0.001)
        XCTAssertTrue(job.suggestedAction.contains("command-line job in Terminal"))
        XCTAssertEqual(job.workloadSummary, "Command-line job in Terminal · 11 processes")
        XCTAssertTrue(job.workloadExplanation.contains("started in Terminal"))

        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(92), activity: result, at: now)
        let insight = ThermalAppInsight.evaluate(activity: result, diagnosis: diagnosis, at: now)
        XCTAssertEqual(insight.title, "Start with make")
        XCTAssertTrue(insight.evidence.contains("\(ThermalActivityFormat.percent(95.1)) of total CPU capacity"), insight.evidence)
    }

    /// make runs recipes through a non-interactive `sh -c`; those shells are
    /// part of the build, not job boundaries.
    func testRecipeShellsCollapseIntoTheMakeJob() throws {
        var processes = terminalShell() + [process(603, parent: 602, name: "make", path: "/usr/bin/make", cpu: 1)]
        for index in 0..<10 {
            let shell = Int32(610 + index * 2)
            let command = "c++ -O2 -c src/file\(index).cpp"
            processes.append(process(shell, parent: 603, name: "sh", path: "/bin/sh", cpu: 0, command: "/bin/sh -c \(command)"))
            processes.append(process(shell + 1, parent: shell, name: "c++", path: "/usr/bin/c++", cpu: 95, command: command))
        }
        let slack = "/Applications/Slack.app/Contents"
        processes += [process(700, parent: 1, name: "Slack", path: "\(slack)/MacOS/Slack", cpu: 20),
                      process(701, parent: 700, name: "Slack Helper (Renderer)",
                              path: "\(slack)/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)", cpu: 110)]
        let result = projection(processes)
        let job = try XCTUnwrap(result.contributors.first)
        XCTAssertEqual(job.displayName, "make")
        XCTAssertEqual(job.kind, .job)
        XCTAssertEqual(job.processCount, 21)
        XCTAssertEqual(job.cpuCapacityPercent, 95.1, accuracy: 0.001)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(92), activity: result, at: now)
        XCTAssertEqual(ThermalAppInsight.evaluate(activity: result, diagnosis: diagnosis, at: now).title, "Start with make")
    }

    /// A shell someone types into still ends the climb, whatever its argv.
    func testInteractiveShellsStayJobBoundaries() {
        let result = projection(terminalShell() + [
            process(603, parent: 602, name: "bash", path: "/bin/bash", cpu: 0, command: "bash -i"),
            process(604, parent: 603, name: "python3", path: "/usr/bin/python3", cpu: 90),
        ])
        XCTAssertEqual(result.contributors.first?.id, "job:604:2000199000.0")
    }

    func testShortLivedCompilerChildrenKeepOneHistoryIdentity() {
        var history = ThermalActivityHistory()
        var current = ThermalActivitySummary.empty
        for (index, offset) in [0.0, 10, 25].enumerated() {
            let date = now.addingTimeInterval(offset)
            let clang = process(Int32(700 + index), parent: 603, name: "clang", path: "/usr/bin/clang", cpu: 180,
                                start: 2_000_199_000 + UInt64(offset), at: date)
            let summary = ThermalActivityAnalyzer.project(
                processes: terminalShell(at: date) + [process(603, parent: 602, name: "make", path: "/usr/bin/make", cpu: 1, at: date), clang],
                families: [], now: date, processorCount: 10)
            current = history.record(summary, at: date)
        }
        XCTAssertEqual(current.recentContributors.count, 1)
        XCTAssertEqual(current.recentContributors.first?.id, "job:603:2000199000.0")
        XCTAssertEqual(current.recentContributors.first?.activeSampleCount, 3)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(84, at: current.sampledAt), activity: current,
                                                  at: current.sampledAt)
        XCTAssertEqual(ThermalAppInsight.evaluate(activity: current, diagnosis: diagnosis, at: current.sampledAt)
            .evidenceStrength, .repeated)
    }

    func testHelpersWithUnresolvedPathsJoinTheirApplication() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let processes = [process(300, parent: 1, name: "Google Chrome", path: chrome, cpu: 20)] +
            (0..<12).map { process(Int32(400 + $0), parent: 300, name: "Google Chrome He", path: "", cpu: 9) }
        let result = projection(processes)
        XCTAssertEqual(result.contributors.count, 1)
        XCTAssertEqual(result.contributors.first?.displayName, "Google Chrome")
        XCTAssertEqual(result.contributors.first?.kind, .app)
        XCTAssertEqual(result.contributors.first?.processCount, 13)
        XCTAssertEqual(result.contributors.first?.cpuPercent ?? 0, 128, accuracy: 0.001)
        XCTAssertEqual(result.contributors.first?.applicationPath, "/Applications/Google Chrome.app")
    }

    func testEditorExtensionHostWorkBelongsToTheEditor() {
        let result = projection(editor() + [process(502, parent: 501, name: "node", path: "/opt/homebrew/bin/node", cpu: 150)])
        XCTAssertEqual(result.contributors.map(\.displayName), ["Visual Studio Code"])
        XCTAssertEqual(result.contributors.first?.processCount, 3)
    }

    func testJobInAnEditorsIntegratedTerminalIsNotBlamedOnTheEditor() {
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        let result = projection(editor() + [
            process(503, parent: 500, name: "Code Helper", path: helper, cpu: 1),
            process(504, parent: 503, name: "zsh", path: "/bin/zsh", cpu: 0),
            process(505, parent: 504, name: "node", path: "/opt/homebrew/bin/node", cpu: 150)
        ])
        let node = result.contributors.first { $0.displayName == "node" }
        XCTAssertEqual(node?.id, "job:505:2000199000.0")
        XCTAssertEqual(node?.kind, .job)
        XCTAssertNil(node?.hostAppName, "An editor is not a terminal host")
        XCTAssertEqual(result.contributors.first { $0.displayName == "Visual Studio Code" }?.cpuPercent, 8)
    }

    func testTmuxIsAJobBoundary() {
        let result = projection([
            process(800, parent: 1, name: "tmux", path: "/opt/homebrew/bin/tmux", cpu: 0),
            process(801, parent: 800, name: "zsh", path: "/bin/zsh", cpu: 0),
            process(802, parent: 801, name: "python3", path: "/usr/bin/python3", cpu: 90),
            process(803, parent: 800, name: "htop", path: "/opt/homebrew/bin/htop", cpu: 60)
        ])
        XCTAssertEqual(Set(result.contributors.map(\.id)), ["job:802:2000199000.0", "job:803:2000199000.0"])
        XCTAssertTrue(result.contributors.allSatisfy { $0.hostAppName == nil })
    }

    func testRecycledParentPIDIsNotFollowed() {
        var resolver = ThermalWorkloadResolver(processes: [
            process(900, parent: 1, name: "Editor", path: "/Applications/Editor.app/Contents/MacOS/Editor", cpu: 0,
                    start: 2_000_199_500),
            process(901, parent: 900, name: "worker", path: "/usr/local/bin/worker", cpu: 50, start: 2_000_199_000)
        ])
        let assignment = resolver.assignment(for: process(901, parent: 900, name: "worker", path: "/usr/local/bin/worker",
                                                          cpu: 50, start: 2_000_199_000))
        XCTAssertEqual(assignment.groupKey, "job:901:2000199000.0")
        XCTAssertEqual(assignment.kind, .process)
    }

    func testCyclesAndDeepChainsTerminateWithinTheHopLimit() {
        let loop = [process(20, parent: 21, name: "a", path: "/bin/a", cpu: 10),
                    process(21, parent: 20, name: "b", path: "/bin/b", cpu: 10)]
        var resolver = ThermalWorkloadResolver(processes: loop)
        XCTAssertEqual(resolver.assignment(for: loop[0]).groupKey, "job:21:2000199000.0")
        XCTAssertLessThanOrEqual(resolver.visitedHops, 1)

        let chain = [process(1000, parent: 1, name: "App", path: "/Applications/Deep.app/Contents/MacOS/Deep", cpu: 0)] +
            (1...40).map { process(Int32(1000 + $0), parent: Int32(999 + $0), name: "step", path: "/bin/step", cpu: 1) }
        var deep = ThermalWorkloadResolver(processes: chain)
        let assignment = deep.assignment(for: chain[40])
        XCTAssertEqual(assignment.groupKey, "job:1024:2000199000.0", "Stops after 16 hops, far below the app")
        XCTAssertEqual(deep.visitedHops, ThermalWorkloadResolver.maximumHops)
    }

    func testHiddenHeatSourcesAreLabelledAndSystemFramed() throws {
        let vm = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        let result = projection([
            process(50, parent: 1, name: "com.apple.Virtualization.Virtua", path: vm, cpu: 400),
            process(51, parent: 1, name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores", cpu: 60),
            process(52, parent: 1, name: "mdworker_shared", path: "", cpu: 30),
            process(53, parent: 1, name: "WindowServer", path: "", cpu: 40)
        ])
        let machine = try XCTUnwrap(result.contributors.first { $0.knownSource == .virtualMachine })
        XCTAssertEqual(machine.displayName, "Linux virtual machine")
        XCTAssertTrue(ThermalKnownSource.virtualMachine.label.contains("Docker Desktop"))
        XCTAssertTrue(machine.isSystemProcess, "Known sources are never framed as apps to stop")
        XCTAssertEqual(machine.suggestedAction, ThermalKnownSource.virtualMachine.advice)
        XCTAssertEqual(machine.workloadSummary, "Docker Desktop, colima, OrbStack, Lima or UTM")
        let spotlight = try XCTUnwrap(result.contributors.first { $0.knownSource == .spotlight })
        XCTAssertEqual(spotlight.displayName, "Spotlight indexing")
        XCTAssertEqual(spotlight.processCount, 2)
        XCTAssertEqual(spotlight.workloadSummary, "macOS background work")
        XCTAssertEqual(result.contributors.first { $0.knownSource == .windowServer }?.displayName, "Screen drawing")
        XCTAssertNil(ThermalKnownSource.matching(name: "com.apple.Virtua", executablePath: ""), "Too short to be unambiguous")
    }

    /// PROC_FLAG_SYSTEM marks only the kernel, so a daemon that runs as the user
    /// (suggestd, cloudd, sharingd) used to read as an app: app advice, the app
    /// icon and, when it repeated while hot, a Stop shortcut.
    func testMacOSDaemonsRunningAsTheUserAreServices() throws {
        let suggestd = "/System/Library/PrivateFrameworks/CoreSuggestions.framework/Versions/A/Support/suggestd"
        let daemon = process(701, parent: 1, name: "suggestd", path: suggestd, cpu: 90)
        let plist = process(710, parent: 602, name: "PlistBuddy", path: "/usr/libexec/PlistBuddy", cpu: 90)
        let script = process(711, parent: 602, name: "python3", path: "/usr/bin/python3", cpu: 90)
        let finder = process(720, parent: 1, name: "Finder",
                             path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", cpu: 90)
        let family = RefreshPerformanceFixture.family(daemon)
        let result = ThermalActivityAnalyzer.project(processes: terminalShell() + [daemon, plist, script, finder],
                                                     families: [family], now: now, processorCount: 10)

        let service = try XCTUnwrap(result.contributors.first { $0.displayName == "suggestd" })
        XCTAssertTrue(service.isSystemProcess)
        XCTAssertEqual(service.workloadSummary, "macOS service")
        XCTAssertTrue(service.suggestedAction.contains("macOS service"), service.suggestedAction)
        XCTAssertNil(ThermalStopTarget.resolve(for: service, family: family, ownPID: 1),
                     "A macOS service is never offered for stopping")

        XCTAssertEqual(result.contributors.first { $0.displayName == "PlistBuddy" }?.isSystemProcess, false,
                       "A tool someone ran from a shell is their job, wherever it lives")
        XCTAssertEqual(result.contributors.first { $0.displayName == "python3" }?.isSystemProcess, false)
        XCTAssertEqual(result.contributors.first { $0.displayName == "Finder" }?.isSystemProcess, false,
                       "Apple's own apps are still apps you use")
    }

    /// bird, cloudd and fileproviderd are one iCloud sync, not three anonymous
    /// rows; the security daemons that vet a fresh build or download likewise.
    func testDaemonsThatExplainHeatAreKnownSources() throws {
        let frameworks = "/System/Library/PrivateFrameworks"
        let result = projection([
            process(60, parent: 1, name: "bird", path: "\(frameworks)/iCloudDriveCore.framework/Versions/A/Support/bird", cpu: 30),
            process(61, parent: 1, name: "cloudd", path: "\(frameworks)/CloudKitDaemon.framework/Support/cloudd", cpu: 30),
            process(62, parent: 1, name: "fileproviderd", path: "\(frameworks)/FileProvider.framework/Support/fileproviderd", cpu: 30),
            process(63, parent: 1, name: "syspolicyd", path: "/usr/libexec/syspolicyd", cpu: 60),
            process(64, parent: 1, name: "XprotectService", path: "", cpu: 40),
            process(65, parent: 1, name: "softwareupdated",
                    path: "/System/Library/CoreServices/Software Update.app/Contents/Resources/softwareupdated", cpu: 20)
        ])
        let cloud = try XCTUnwrap(result.contributors.first { $0.knownSource == .cloudSync })
        XCTAssertEqual(cloud.displayName, "iCloud sync")
        XCTAssertEqual(cloud.processCount, 3)
        XCTAssertTrue(cloud.isSystemProcess)
        XCTAssertEqual(cloud.suggestedAction, ThermalKnownSource.cloudSync.advice)
        XCTAssertEqual(cloud.workloadSummary, "iCloud Drive, CloudKit and cloud-storage folders")
        let security = try XCTUnwrap(result.contributors.first { $0.knownSource == .securityChecks })
        XCTAssertEqual(security.displayName, "Security checks")
        XCTAssertEqual(security.processCount, 2, "An unresolved path still matches a macOS daemon's name")
        XCTAssertTrue(security.isSystemProcess)
        XCTAssertEqual(security.suggestedAction, ThermalKnownSource.securityChecks.advice)
        let update = try XCTUnwrap(result.contributors.first { $0.knownSource == .softwareUpdate })
        XCTAssertEqual(update.displayName, "Software update")
        XCTAssertEqual(update.processCount, 1, "The bundle path does not make it an app")
        XCTAssertEqual(result.contributors.count, 3, "Six daemons, three explanations")

        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(90), activity: result, at: now)
        XCTAssertEqual(ThermalAppInsight.evaluate(activity: result, diagnosis: diagnosis, at: now).title,
                       "Start with Security checks")
    }

    /// The iOS Simulator runs its own cloudd, trustd and installd under a path that
    /// contains "/System/Library/", and people build tools with these names.
    func testSharedDaemonNamesNeedMacOSsOwnFolder() {
        let simulator = "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.0.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd"
        XCTAssertNil(ThermalKnownSource.matching(name: "cloudd", executablePath: simulator))
        XCTAssertNil(ThermalKnownSource.matching(name: "bird", executablePath: "/Users/me/bin/bird"))
        XCTAssertNil(ThermalKnownSource.matching(name: "installd", executablePath: "/opt/homebrew/bin/installd"))
        XCTAssertEqual(ThermalKnownSource.matching(name: "trustd", executablePath: "/usr/libexec/trustd"), .securityChecks)
        XCTAssertEqual(ThermalKnownSource.matching(name: "trustd", executablePath: ""), .securityChecks)

        let result = projection([process(70, parent: 1, name: "bird", path: "/Users/me/bin/bird", cpu: 90)])
        XCTAssertEqual(result.contributors.first?.kind, .process)
        XCTAssertNil(result.contributors.first?.knownSource)
        XCTAssertFalse(result.contributors.first?.isSystemProcess ?? true)
    }

    /// A daemon whose path could not be read is still not something to stop.
    func testAnExplainedDaemonWithoutAPathGetsNoStopShortcut() throws {
        let daemon = process(80, parent: 1, name: "syspolicyd", path: "", cpu: 90)
        let family = RefreshPerformanceFixture.family(daemon)
        let result = ThermalActivityAnalyzer.project(processes: [daemon], families: [family], now: now, processorCount: 10)
        let contributor = try XCTUnwrap(result.contributors.first)
        XCTAssertEqual(contributor.knownSource, .securityChecks)
        XCTAssertNil(ThermalStopTarget.resolve(for: contributor, family: family, ownPID: 1))
    }

    /// macOS keeps a terminal responsible for what it started, even once the job
    /// is orphaned to launchd (nohup, a daemonized server, colima). That is a job
    /// started in the terminal, not the terminal's own work.
    func testAnOrphanedJobResponsibleToATerminalIsAJobInIt() throws {
        let node = process(610, parent: 1, name: "node", path: "/opt/homebrew/bin/node", cpu: 80)
        let child = process(611, parent: 610, name: "esbuild", path: "/opt/homebrew/bin/esbuild", cpu: 40)
        let result = ThermalActivityAnalyzer.project(
            processes: terminalShell() + [node, child], families: [], now: now, processorCount: 10,
            responsiblePIDs: [node.identity: 600])
        let job = try XCTUnwrap(result.contributors.first)
        XCTAssertEqual(result.contributors.count, 1)
        XCTAssertEqual(job.id, "job:610:2000199000.0")
        XCTAssertEqual(job.displayName, "node")
        XCTAssertEqual(job.kind, .job)
        XCTAssertEqual(job.hostAppName, "Terminal")
        XCTAssertEqual(job.processCount, 2)
    }

    /// A platform helper the terminal is responsible for (an open panel, a view
    /// bridge) is still counted with the terminal, as before.
    func testPlatformHelpersResponsibleToATerminalStayWithIt() {
        let viewBridge = "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/ViewBridgeAuxiliary"
        let bridge = process(620, parent: 1, name: "ViewBridgeAuxiliary", path: viewBridge, cpu: 60)
        let service = process(621, parent: 1, name: "diagnosticd", path: "/usr/libexec/diagnosticd", cpu: 60)
        var resolver = ThermalWorkloadResolver(processes: terminalShell() + [bridge, service],
                                               responsiblePIDs: [bridge.identity: 600, service.identity: 600])
        for helper in [bridge, service] {
            let assignment = resolver.assignment(for: helper)
            XCTAssertTrue(assignment.kind == .app, "\(helper.name) is \(assignment.kind)")
            XCTAssertEqual(assignment.groupKey, "/System/Applications/Utilities/Terminal.app")
        }
    }

    /// A pid reused after the responsible app quit would name a stranger.
    func testAResponsibleAppThatStartedAfterTheJobIsARecycledPID() {
        let editor = process(630, parent: 1, name: "Editor", path: "/Applications/Editor.app/Contents/MacOS/Editor",
                             cpu: 0, start: 2_000_199_500)
        let orphan = process(631, parent: 1, name: "worker", path: "/usr/local/bin/worker", cpu: 50)
        var resolver = ThermalWorkloadResolver(processes: [editor, orphan], responsiblePIDs: [orphan.identity: 630])
        let assignment = resolver.assignment(for: orphan)
        XCTAssertEqual(assignment.kind, .process)
        XCTAssertEqual(assignment.groupKey, "job:631:2000199000.0")
    }

    // MARK: - Xcode's command-line tools

    /// With Xcode selected, the xcrun shims for swift, clang, git, make and python3 run
    /// programs from inside Xcode.app. Started from a shell they are that shell's job.
    func testToolchainBinariesInsideXcodeStartedFromAShellAreTheShellsJob() throws {
        let build = process(603, parent: 602, name: "swift-build", path: "\(toolchain)/swift-build", cpu: 40)
        let frontends = (0..<4).map {
            process(Int32(610 + $0), parent: 603, name: "swift-frontend", path: "\(toolchain)/swift-frontend", cpu: 98)
        }
        let result = projection(terminalShell() + [build] + frontends)
        let job = try XCTUnwrap(result.contributors.first)
        XCTAssertEqual(result.contributors.count, 1)
        XCTAssertEqual(job.displayName, "swift-build")
        XCTAssertEqual(job.kind, .job)
        XCTAssertEqual(job.hostAppName, "Terminal")
        XCTAssertNil(job.applicationPath)
        XCTAssertEqual(job.processCount, 5)
        let diagnosis = ThermalDiagnosis.evaluate(snapshot: snapshot(90), activity: result, at: now)
        XCTAssertEqual(ThermalAppInsight.evaluate(activity: result, diagnosis: diagnosis, at: now).title,
                       "Start with swift-build")
    }

    /// The python3 shim runs a Python.app nested in Xcode's frameworks, and make
    /// runs each recipe through a `sh -c` that is not inside any app.
    func testPythonAndMakeThroughTheXcodeShimsAreJobsToo() throws {
        let python = "\(xcode)/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        var processes = terminalShell() + [
            process(620, parent: 602, name: "Python", path: python, cpu: 90, command: "python3 train.py"),
            process(603, parent: 602, name: "make", path: "\(xcode)/Contents/Developer/usr/bin/make", cpu: 1)
        ]
        for index in 0..<3 {
            let shell = Int32(630 + index * 2)
            let command = "clang -c file\(index).c"
            processes.append(process(shell, parent: 603, name: "sh", path: "/bin/sh", cpu: 0, command: "/bin/sh -c \(command)"))
            processes.append(process(shell + 1, parent: shell, name: "clang", path: "\(toolchain)/clang", cpu: 95, command: command))
        }
        let result = projection(processes)
        XCTAssertEqual(result.contributors.count, 2)
        let make = try XCTUnwrap(result.contributors.first { $0.displayName == "make" })
        XCTAssertEqual(make.kind, .job)
        XCTAssertEqual(make.processCount, 7)
        XCTAssertEqual(make.hostAppName, "Terminal")
        let script = try XCTUnwrap(result.contributors.first { $0.displayName == "Python" })
        XCTAssertEqual(script.kind, .job)
        XCTAssertEqual(script.hostAppName, "Terminal")
    }

    /// xcodebuild runs its work through XCBBuildService, which lives in Xcode.app too;
    /// only Xcode's own main process owns a build as the app.
    func testAShellsXcodebuildAndItsFrontendsAreOneJob() throws {
        let service = "\(xcode)/Contents/SharedFrameworks/XCBuild.framework/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService"
        let result = projection(terminalShell() + [
            process(603, parent: 602, name: "xcodebuild", path: "\(xcode)/Contents/Developer/usr/bin/xcodebuild", cpu: 5),
            process(604, parent: 603, name: "XCBBuildService", path: service, cpu: 5),
            process(610, parent: 604, name: "swift-frontend", path: "\(toolchain)/swift-frontend", cpu: 98),
            process(611, parent: 604, name: "swift-frontend", path: "\(toolchain)/swift-frontend", cpu: 98)
        ])
        let job = try XCTUnwrap(result.contributors.first { $0.displayName == "xcodebuild" })
        XCTAssertEqual(job.kind, .job)
        XCTAssertEqual(job.hostAppName, "Terminal")
        XCTAssertEqual(job.processCount, 3, "xcodebuild and the frontends it ran through its build service")
    }

    /// An editor's language server or git call is the editor's, wherever the tool lives.
    func testToolsAnEditorStartsAreTheEditorsNotXcodes() {
        let git = process(510, parent: 501, name: "git", path: "\(xcode)/Contents/Developer/usr/bin/git", cpu: 120)
        let result = projection(editor() + [git])
        XCTAssertEqual(result.contributors.map(\.displayName), ["Visual Studio Code"])
        XCTAssertEqual(result.contributors.first?.kind, .app)
        XCTAssertEqual(result.contributors.first?.processCount, 3)
    }

    /// Guards: what Xcode itself runs, and apps started from a shell, stay apps.
    func testXcodesOwnWorkAndAppsStartedFromAShellStayApps() {
        let service = "\(xcode)/Contents/SharedFrameworks/XCBuild.framework/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService"
        let xcodeWork = [
            process(700, parent: 1, name: "Xcode", path: "\(xcode)/Contents/MacOS/Xcode", cpu: 10),
            process(701, parent: 700, name: "XCBBuildService", path: service, cpu: 5),
            process(702, parent: 701, name: "swift-frontend", path: "\(toolchain)/swift-frontend", cpu: 98),
            // A run-script build phase goes through a shell too.
            process(703, parent: 701, name: "sh", path: "/bin/sh", cpu: 0, command: "/bin/sh -c run-script.sh"),
            process(704, parent: 703, name: "clang", path: "\(toolchain)/clang", cpu: 98),
            // launchd starts SourceKit's service and the debugger.
            process(705, parent: 1, name: "SourceKitService",
                    path: "\(toolchain)/../lib/sourcekitd/SourceKitService.xpc/Contents/MacOS/SourceKitService", cpu: 30),
            // A GUI tool inside Xcode, started from a shell, is not a command-line job.
            process(706, parent: 602, name: "Simulator", path: "\(xcode)/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator", cpu: 30),
            process(707, parent: 602, name: "Foo", path: "/Applications/Foo.app/Contents/MacOS/Foo", cpu: 30),
            process(708, parent: 707, name: "Foo Helper", path: "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper", cpu: 30)
        ]
        let result = projection(terminalShell() + xcodeWork)
        XCTAssertTrue(result.contributors.allSatisfy { $0.kind == .app }, "\(result.contributors.map(\.displayName))")
        XCTAssertEqual(Set(result.contributors.map(\.displayName)), ["Xcode", "Foo"])
        XCTAssertEqual(result.contributors.first { $0.displayName == "Foo" }?.processCount, 2)
        XCTAssertEqual(result.contributors.first { $0.displayName == "Xcode" }?.processCount, 7)
    }

    func testProjectionDoesNotDependOnInputOrder() {
        let processes = terminalShell() + editor() + [
            process(603, parent: 602, name: "make", path: "/usr/bin/make", cpu: 3),
            process(610, parent: 603, name: "clang", path: "/usr/bin/clang", cpu: 80),
            process(502, parent: 501, name: "node", path: "/opt/homebrew/bin/node", cpu: 40)
        ]
        XCTAssertEqual(projection(processes), projection(processes.reversed()))
        XCTAssertEqual(projection(processes), projection(processes.sorted { $0.name < $1.name }))
    }

    func testLargeInventoryResolvesInLinearHops() {
        // A single deep chain is the worst case for walking parents.
        let processes = (0..<2_000).map { (index: Int) -> ProcessMetrics in
            let pid = Int32(10_000 + index)
            return process(pid, parent: index == 0 ? 1 : pid - 1, name: "step-\(index)", path: "/bin/step", cpu: 1)
        }
        var resolver = ThermalWorkloadResolver(processes: processes)
        for process in processes { _ = resolver.assignment(for: process) }
        XCTAssertLessThanOrEqual(resolver.visitedHops, processes.count * ThermalWorkloadResolver.maximumHops)
        let before = resolver.visitedHops
        for process in processes { _ = resolver.assignment(for: process) }
        XCTAssertEqual(resolver.visitedHops, before, "Repeated lookups are memoized")
        XCTAssertEqual(projection(processes).observedProcessCount, 2_000)
    }

    private func projection(_ processes: [ProcessMetrics]) -> ThermalActivitySummary {
        ThermalActivityAnalyzer.project(processes: processes, families: [], now: now, processorCount: 10)
    }

    private func terminalShell(at date: Date? = nil) -> [ProcessMetrics] {
        [process(600, parent: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", cpu: 0, at: date),
         process(601, parent: 600, name: "login", path: "/usr/bin/login", cpu: 0, at: date),
         process(602, parent: 601, name: "-zsh", path: "/bin/zsh", cpu: 0, at: date)]
    }

    private func editor() -> [ProcessMetrics] {
        let app = "/Applications/Visual Studio Code.app"
        return [process(500, parent: 1, name: "Electron", path: "\(app)/Contents/MacOS/Electron", cpu: 5),
                process(501, parent: 500, name: "Code Helper (Plugin)",
                        path: "\(app)/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", cpu: 2)]
    }

    private func snapshot(_ celsius: Double, at date: Date? = nil) -> ThermalSnapshot {
        ThermalSnapshot(sampledAt: date ?? now, cpuCelsius: celsius, gpuCelsius: nil, sensorCount: 1,
                        sensorKeys: [], systemState: "Nominal", unavailableReason: nil)
    }

    private func process(_ pid: Int32, parent: Int32, name: String, path: String, cpu: Double,
                         start: UInt64 = 2_000_199_000, at date: Date? = nil, command: String? = nil) -> ProcessMetrics {
        ProcessMetrics(identity: ProcessIdentity(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
            parentPID: parent, userID: 501, ownerName: "fixture", name: name, executablePath: path,
            commandLine: command ?? name, residentMemoryBytes: 1, physicalFootprintBytes: 1, virtualMemoryBytes: 1,
            cpuPercent: cpu, totalProcessorSeconds: 1, threadCount: 1, isSystemProcess: false,
            sampledAt: date ?? now)
    }
}
