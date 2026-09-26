import Foundation
@testable import GhostProcessSniperCore

/// A deterministic developer Mac: editors with helper trees and language
/// servers, dev servers, a build, a test-worker pool, duplicate servers,
/// databases, system daemons and filler tools. `tick` advances time and
/// grows a few families, so trends and caches see realistic churn.
enum DevWorkstationFixture {
    static let start = Date(timeIntervalSince1970: 2_000_000_000)
    static let cadence: TimeInterval = 3
    static let user: UInt32 = 501
    static let mib: UInt64 = 1_048_576

    static func date(tick: Int) -> Date {
        start.addingTimeInterval(Double(tick) * cadence)
    }

    static func processes(count: Int = 600, tick: Int) -> [ProcessMetrics] {
        var builder = Builder(tick: tick)
        builder.addScenario()
        var filler = 0
        while builder.processes.count < count {
            builder.addFiller(filler)
            filler += 1
        }
        return Array(builder.processes.prefix(count))
    }

    private struct Builder {
        let tick: Int
        var processes: [ProcessMetrics] = []
        var nextPID: Int32 = 1_000

        init(tick: Int) {
            self.tick = tick
        }

        var now: Date { DevWorkstationFixture.date(tick: tick) }

        @discardableResult
        mutating func add(
            parent: Int32,
            name: String,
            path: String,
            command: String,
            megabytes: Double,
            cpu: Double = 0,
            user: UInt32 = DevWorkstationFixture.user,
            system: Bool = false,
            ageSeconds: TimeInterval = 7_200
        ) -> Int32 {
            let pid = nextPID
            nextPID += 1
            let bytes = UInt64(max(1, megabytes) * Double(mib))
            let started = start.addingTimeInterval(-ageSeconds)
            processes.append(ProcessMetrics(
                identity: ProcessIdentity(pid: pid, startTimeSeconds: UInt64(started.timeIntervalSince1970), startTimeMicroseconds: 0),
                parentPID: parent, userID: user, ownerName: user == 0 ? "root" : "dev", name: name,
                executablePath: path, commandLine: command, residentMemoryBytes: bytes,
                physicalFootprintBytes: bytes, virtualMemoryBytes: bytes * 4, cpuPercent: cpu,
                totalProcessorSeconds: cpu / 100 * (ageSeconds + Double(tick) * cadence),
                threadCount: 8, isSystemProcess: system, sampledAt: now
            ))
            return pid
        }

        mutating func addScenario() {
            let t = Double(tick)
            let launchd: Int32 = 1
            let terminal = add(parent: launchd, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                               command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", megabytes: 180, system: true)
            let shell = add(parent: terminal, name: "zsh", path: "/bin/zsh", command: "-zsh", megabytes: 6)

            // Visual Studio Code with helpers, a TypeScript server and a leaking rust-analyzer.
            let codeApp = "/Applications/Visual Studio Code.app"
            let code = add(parent: launchd, name: "Electron", path: "\(codeApp)/Contents/MacOS/Electron",
                           command: "\(codeApp)/Contents/MacOS/Electron", megabytes: 420, cpu: 3)
            for index in 0..<3 {
                add(parent: code, name: "Code Helper (Renderer)",
                    path: "\(codeApp)/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)",
                    command: "Code Helper (Renderer) --type=renderer --renderer-client-id=\(index + 4)", megabytes: 300 + Double(index) * 40, cpu: 2)
            }
            let plugin = add(parent: code, name: "Code Helper (Plugin)",
                             path: "\(codeApp)/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                             command: "Code Helper (Plugin) --type=utility --utility-sub-type=node.mojom.NodeService", megabytes: 260, cpu: 4)
            add(parent: plugin, name: "node", path: "/usr/local/bin/node",
                command: "node /Users/dev/app/node_modules/typescript/lib/tsserver.js --serverMode partialSemantic", megabytes: 480, cpu: 6)
            add(parent: plugin, name: "rust-analyzer", path: "/Users/dev/.vscode/extensions/rust-lang.rust-analyzer-0.3.2/server/rust-analyzer",
                command: "/Users/dev/.vscode/extensions/rust-lang.rust-analyzer-0.3.2/server/rust-analyzer", megabytes: 1_800 + t * 20, cpu: 12)

            // Vite dev server started from the terminal, with esbuild.
            let vite = add(parent: shell, name: "node", path: "/usr/local/bin/node",
                           command: "node /Users/dev/web/node_modules/.bin/vite --port 5173", megabytes: 350 + t * 2, cpu: 8)
            add(parent: vite, name: "esbuild", path: "/Users/dev/web/node_modules/@esbuild/darwin-arm64/bin/esbuild",
                command: "/Users/dev/web/node_modules/@esbuild/darwin-arm64/bin/esbuild --service=0.19.2 --ping", megabytes: 40, cpu: 1)

            // Three forgotten copies of the same server under launchd.
            for index in 0..<3 {
                add(parent: launchd, name: "node", path: "/usr/local/bin/node",
                    command: "node /Users/dev/api/server.js --port \(3000 + index)", megabytes: 210 + Double(index) * 5, cpu: 0.3,
                    ageSeconds: 14_400)
            }

            // A jest worker pool.
            let jest = add(parent: shell, name: "node", path: "/usr/local/bin/node",
                           command: "node /Users/dev/web/node_modules/.bin/jest --watch", megabytes: 150, cpu: 20)
            for _ in 0..<6 {
                add(parent: jest, name: "node", path: "/usr/local/bin/node",
                    command: "node /Users/dev/web/node_modules/jest-worker/build/workers/processChild.js", megabytes: 120, cpu: 45)
            }

            // A Swift build.
            let build = add(parent: shell, name: "swift-build", path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build",
                            command: "swift build -c release", megabytes: 220, cpu: 40, ageSeconds: 60)
            for index in 0..<4 {
                add(parent: build, name: "swift-frontend",
                    path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                    command: "swift-frontend -frontend -c -primary-file Sources/App/File\(index + Int(t) % 3).swift -o /private/var/folders/xy/T/File\(index).o",
                    megabytes: 700, cpu: 98, ageSeconds: 20)
            }

            // Python services and a notebook kernel.
            add(parent: shell, name: "python3.12", path: "/opt/homebrew/bin/python3.12",
                command: "python3.12 -m uvicorn app.main:app --reload --port 8000", megabytes: 190, cpu: 2)
            add(parent: launchd, name: "python3", path: "/opt/homebrew/bin/python3",
                command: "python3 -m ipykernel_launcher -f /Users/dev/Library/Jupyter/runtime/kernel-4f1c2a.json", megabytes: 900 + t * 30, cpu: 0)

            // Databases, containers and a model runner.
            add(parent: launchd, name: "postgres", path: "/opt/homebrew/opt/postgresql@16/bin/postgres",
                command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16", megabytes: 90, cpu: 1)
            add(parent: launchd, name: "redis-server", path: "/opt/homebrew/opt/redis/bin/redis-server",
                command: "/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379", megabytes: 30, cpu: 0.5)
            add(parent: launchd, name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
                command: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", megabytes: 600, cpu: 5)
            add(parent: launchd, name: "ollama", path: "/usr/local/bin/ollama", command: "ollama serve", megabytes: 5_200, cpu: 150)

            // A runaway spin loop and Xcode itself.
            add(parent: launchd, name: "node", path: "/usr/local/bin/node", command: "node /Users/dev/scripts/poll.js", megabytes: 80, cpu: 99.5)
            add(parent: launchd, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode",
                command: "/Applications/Xcode.app/Contents/MacOS/Xcode", megabytes: 1_400, cpu: 4)
            add(parent: launchd, name: "SourceKitService",
                path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService",
                command: "SourceKitService", megabytes: 1_100, cpu: 30)

            // Ordinary apps and system daemons.
            add(parent: launchd, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari",
                command: "/Applications/Safari.app/Contents/MacOS/Safari", megabytes: 700, cpu: 3)
            add(parent: launchd, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                command: "WindowServer -daemon", megabytes: 900, cpu: 15, user: 88, system: true)
            for index in 0..<4 {
                add(parent: launchd, name: "mdworker_shared", path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mdworker_shared",
                    command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mdworker_shared -s mdworker -c MDSImporterWorker -m com.apple.mdworker.shared.0\(index)",
                    megabytes: 20, cpu: 0.2, system: true)
            }
            add(parent: launchd, name: "nginx", path: "/opt/homebrew/bin/nginx", command: "nginx: master process /opt/homebrew/bin/nginx -g daemon off; server",
                megabytes: 25, cpu: 0.1, user: 0)
        }

        mutating func addFiller(_ index: Int) {
            let group = index / 3
            let parent: Int32 = index % 7 == 0 ? 1 : 1_001
            switch index % 5 {
            case 0:
                add(parent: parent, name: "fixture-tool-\(group)", path: "/usr/local/bin/fixture-tool-\(group)",
                    command: "fixture-tool-\(group) --fixture \(index)", megabytes: Double(20 + index % 90), cpu: Double(index % 4))
            case 1:
                add(parent: 1, name: "com.apple.agent\(index)", path: "/usr/libexec/agent\(index)",
                    command: "/usr/libexec/agent\(index)", megabytes: Double(8 + index % 30), cpu: 0.1, system: true)
            case 2:
                add(parent: 1, name: "App\(group)", path: "/Applications/App\(group).app/Contents/MacOS/App\(group)",
                    command: "/Applications/App\(group).app/Contents/MacOS/App\(group) -psn_0_\(index)", megabytes: Double(60 + index % 200), cpu: Double(index % 3))
            case 3:
                add(parent: 1_001, name: "node", path: "/usr/local/bin/node",
                    command: "node /Users/dev/project\(group)/node_modules/.bin/tsc --watch --project tsconfig.\(index).json",
                    megabytes: Double(90 + index % 60), cpu: Double(index % 6))
            default:
                add(parent: 1, name: "helperd\(index)", path: "/Library/Application Support/Vendor/helperd\(index)",
                    command: "/Library/Application Support/Vendor/helperd\(index) --daemon", megabytes: Double(15 + index % 40), cpu: 0.5,
                    user: index % 2 == 0 ? 0 : DevWorkstationFixture.user)
            }
        }
    }
}
