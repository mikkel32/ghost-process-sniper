import Foundation

/// What kind of work a stop interrupts. It decides how politely to stop it
/// and what could go wrong.
public enum KillWorkloadKind: String, Codable, Sendable {
    case app, editor, dataStore, containerRuntime, versionControl, packageManager, build, devServer, modelRunner, general

    public var label: String {
        switch self {
        case .app: "App"
        case .editor: "Document editor"
        case .dataStore: "Database"
        case .containerRuntime: "Container runtime"
        case .versionControl: "Version control"
        case .packageManager: "Package install"
        case .build: "Build"
        case .devServer: "Dev server"
        case .modelRunner: "Model runner"
        case .general: "Process"
        }
    }
}

public enum KillRiskSeverity: Int, Codable, Comparable, Sendable {
    case info, caution, danger

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum KillRiskKind: String, Codable, Sendable {
    case unsavedWork, dataIntegrity, stopsContainers, lockFile, partialInstall, interruptedBuild,
         respawn, unloadsModels, freesPorts, orphaned
}

public struct KillRisk: Identifiable, Equatable, Sendable {
    public var id: KillRiskKind { kind }
    public let kind: KillRiskKind
    public let severity: KillRiskSeverity
    public let title: String
    public let detail: String

    public init(kind: KillRiskKind, severity: KillRiskSeverity, title: String, detail: String) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
    }

    /// Good news, such as freed ports, rather than a hazard.
    public var isBenefit: Bool { kind == .freesPorts || kind == .orphaned }
}

public enum KillSupervisorKind: String, Codable, Sendable {
    case launchd, nodemon, pm2, forever, supervisord, watchexec, cargoWatch, air, tsxWatch, entr, overmind
}

/// Something that restarts the process after it stops.
public struct KillSupervisor: Equatable, Sendable {
    /// Nil for launchd, which is not a process the user can stop.
    public let pid: Int32?
    public let name: String
    public let kind: KillSupervisorKind
}

public struct KillRiskAssessment: Equatable, Sendable {
    public let kind: KillWorkloadKind
    public let risks: [KillRisk]
    public let supervisor: KillSupervisor?
    /// The app process to ask to quit, like ⌘Q, before any signal.
    public let appQuitPID: Int32?
    /// A longer grace period for work that needs time to shut down cleanly.
    public let graceSeconds: TimeInterval?
    /// Survivors are reported rather than force-killed unless the user asks.
    public let forceNeedsConfirmation: Bool
    public let freedPorts: [Int]
    /// One plain sentence: what stopping this will do.
    public let headline: String?

    public static let none = KillRiskAssessment(
        kind: .general, risks: [], supervisor: nil, appQuitPID: nil, graceSeconds: nil,
        forceNeedsConfirmation: false, freedPorts: [], headline: nil
    )

    public var hazards: [KillRisk] { risks.filter { !$0.isBenefit } }
    public var benefits: [KillRisk] { risks.filter(\.isBenefit) }
    public var highestSeverity: KillRiskSeverity? { hazards.map(\.severity).max() }
}

/// Reads names, paths and command lines to learn what a process is, then
/// predicts the consequences of stopping it: unsaved documents, database
/// corruption, git lock files, half-finished installs, containers going
/// down, and supervisors that will simply start it again.
public struct KillRiskAssessor: Sendable {
    public init() {}

    public func assess(_ workload: KillWorkloadProfile) -> KillRiskAssessment {
        guard let root = workload.root else { return .none }
        let processes = workload.processes.map(Fingerprint.init)
        let rootPrint = Fingerprint(root)
        let appName = rootPrint.appBundleName
        let isAppMain = rootPrint.isAppMainBinary
        let name = appName ?? root.name

        let kind = classify(root: rootPrint, processes: processes)
        let supervisor = findSupervisor(workload, rootPrint: rootPrint, processes: processes)
        let ports = Array(Set(workload.processes.flatMap(\.listeningPorts))).sorted().prefix(8).map { $0 }

        var risks: [KillRisk] = []
        var grace: TimeInterval?
        var confirmForce = false
        var headline: String?

        switch kind {
        case .editor:
            risks.append(KillRisk(kind: .unsavedWork, severity: .danger, title: "Unsaved documents",
                                  detail: "\(name) edits documents. It is asked to quit like \u{2318}Q so it can save or ask you first."))
            grace = 10
            confirmForce = true
            headline = "Asks \(name) to quit like \u{2318}Q so it can save your work. If it asks about unsaved changes, answer it there \u{2014} Ghost won't force it without asking."
        case .app:
            risks.append(KillRisk(kind: .unsavedWork, severity: .caution, title: "Open windows",
                                  detail: "\(name) is asked to quit like \u{2318}Q, so it can restore windows and save state next time."))
            grace = 8
            confirmForce = true
            headline = "Asks \(name) to quit like \u{2318}Q, then stops anything it leaves behind."
        case .dataStore:
            risks.append(KillRisk(kind: .dataIntegrity, severity: .danger, title: "Database writes",
                                  detail: "A forced stop can interrupt writes and corrupt data or trigger a long recovery on next start."))
            grace = 12
            confirmForce = true
            headline = "Asks \(root.name) to shut down cleanly and gives it 12 s to flush data. Ghost won't force it without asking."
        case .containerRuntime:
            risks.append(KillRisk(kind: .stopsContainers, severity: .danger, title: "Every container stops",
                                  detail: "Stopping the runtime shuts down all running containers and their volumes' in-flight writes."))
            grace = 15
            confirmForce = true
            headline = "Shuts \(name) down cleanly, which stops every running container."
        case .versionControl:
            let mutating = rootPrint.isMutatingVersionControl || processes.contains(where: \.isMutatingVersionControl)
            risks.append(KillRisk(kind: .lockFile, severity: mutating ? .caution : .info, title: "Git operation interrupted",
                                  detail: mutating
                                      ? "Stopping git mid-operation can leave .git/index.lock behind. Delete it if git later refuses to run."
                                      : "A read-only git command; stopping it is harmless."))
            if mutating {
                grace = 5
                confirmForce = true
            }
            headline = "Stops git\(mutating ? " mid-operation" : ""). If git later complains about index.lock, delete .git/index.lock."
        case .packageManager:
            risks.append(KillRisk(kind: .partialInstall, severity: .caution, title: "Half-finished install",
                                  detail: "Dependencies may be left partly installed. Run the install again afterwards."))
            grace = 4
            confirmForce = true
            headline = "Stops the install. Run it again afterwards; dependencies may be half-installed."
        case .build:
            risks.append(KillRisk(kind: .interruptedBuild, severity: .info, title: "Build interrupted",
                                  detail: "The build stops; incremental caches stay usable. Rebuild when you are ready."))
            headline = "Stops the build. Rebuild when you are ready; caches stay intact."
        case .devServer:
            headline = ports.isEmpty
                ? "Interrupts the dev server like Ctrl-C, then stops anything that ignores it."
                : "Interrupts the dev server like Ctrl-C and frees \(Self.portList(ports))."
        case .modelRunner:
            risks.append(KillRisk(kind: .unloadsModels, severity: .info, title: "Models unloaded",
                                  detail: "Loaded models leave memory; the next request reloads them, which is slow."))
            headline = "Stops \(root.name) and unloads its models; the next request reloads them."
        case .general:
            break
        }

        if let supervisor {
            let who = supervisor.pid.map { "\(supervisor.name) (PID \($0))" } ?? supervisor.name
            risks.append(KillRisk(
                kind: .respawn, severity: .caution, title: "Will restart",
                detail: supervisor.kind == .launchd
                    ? "launchd manages this process and will likely start it again. Quit the app or disable the login item that owns it."
                    : "\(who) watches this process and restarts it. Stop \(supervisor.name) instead to make it stay stopped."
            ))
        } else if workload.parentIsLaunchd, !isAppMain, kind == .devServer || kind == .build || kind == .general {
            risks.append(KillRisk(kind: .orphaned, severity: .info, title: "Orphaned",
                                  detail: "Its terminal or parent is gone, so nothing will restart it."))
        }
        if !ports.isEmpty {
            risks.append(KillRisk(kind: .freesPorts, severity: .info,
                                  title: ports.count == 1 ? "Frees port \(ports[0])" : "Frees \(ports.count) ports",
                                  detail: "Releases \(Self.portList(ports)) for the next server."))
        }

        return KillRiskAssessment(
            kind: kind,
            risks: risks,
            supervisor: supervisor,
            // Apps, including Docker Desktop and Postgres.app, shut their own
            // work down properly when asked to quit.
            appQuitPID: isAppMain ? root.pid : nil,
            graceSeconds: grace,
            forceNeedsConfirmation: confirmForce,
            freedPorts: ports,
            headline: headline
        )
    }

    // MARK: - Classification

    private func classify(root: Fingerprint, processes: [Fingerprint]) -> KillWorkloadKind {
        let all = [root] + processes
        if all.contains(where: \.isContainerRuntime) { return .containerRuntime }
        if all.contains(where: \.isDataStore) { return .dataStore }
        if root.isVersionControl { return .versionControl }
        if root.isPackageManager || (root.isScriptRunner && processes.contains(where: \.isPackageManager)) {
            return .packageManager
        }
        if root.isAppMainBinary {
            return root.isEditorApp ? .editor : .app
        }
        if all.contains(where: \.isModelRunner) { return .modelRunner }
        if root.isBuildTool || (root.isScriptRunner && processes.contains(where: \.isBuildTool)) { return .build }
        if all.contains(where: \.isDevServer) { return .devServer }
        if processes.contains(where: \.isVersionControl) { return .versionControl }
        return .general
    }

    private func findSupervisor(
        _ workload: KillWorkloadProfile,
        rootPrint: Fingerprint,
        processes: [Fingerprint]
    ) -> KillSupervisor? {
        // A supervisor inside the stop goes down with its children.
        if processes.contains(where: { $0.supervisorKind != nil }) { return nil }
        for ancestor in workload.ancestors {
            let print = Fingerprint(name: ancestor.name, path: ancestor.executablePath, command: ancestor.commandLine)
            if let kind = print.supervisorKind {
                return KillSupervisor(pid: ancestor.pid, name: print.supervisorName ?? ancestor.name, kind: kind)
            }
        }
        if workload.parentIsLaunchd, rootPrint.isLaunchdManagedService {
            return KillSupervisor(pid: nil, name: "launchd", kind: .launchd)
        }
        return nil
    }

    private static func portList(_ ports: [Int]) -> String {
        let list = ports.prefix(4).map(String.init).joined(separator: ", ")
        let more = ports.count > 4 ? " and \(ports.count - 4) more" : ""
        return (ports.count == 1 ? "port " : "ports ") + list + more
    }
}

// MARK: - Fingerprints

/// Lower-cased name, path and argv, with the matchers that classify them.
private struct Fingerprint {
    let name: String
    let path: String
    let rawPath: String
    let binary: String
    let args: [String]
    let command: String
    private let identities: [String]

    init(_ process: KillWorkloadProcess) {
        self.init(name: process.name, path: process.executablePath, command: process.commandLine)
    }

    /// What identifies a workload sits at the front of argv; the rest is
    /// flags and file lists. Electron helpers carry kilobytes of it.
    private static let commandPrefixBytes = 512

    init(name: String, path: String, command: String) {
        self.name = name.lowercased()
        self.path = path.lowercased()
        rawPath = path
        self.command = String(decoding: command.utf8.prefix(Self.commandPrefixBytes), as: UTF8.self).lowercased()
        let tokens = self.command.unicodeScalars.split(whereSeparator: \.properties.isWhitespace).map(String.init)
        let first = tokens.first.map(Self.lastComponent) ?? ""
        binary = first.isEmpty ? self.name : first
        args = Array(tokens.dropFirst())
        identities = [self.name, binary, Self.lastComponent(self.path)]
    }

    private static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private func named(_ candidates: Set<String>) -> Bool {
        identities.contains(where: candidates.contains)
    }

    /// The first argument that is not a flag, e.g. `install` in `npm --silent install`.
    private var verb: String? { args.first { !$0.hasPrefix("-") } }

    private func mentions(_ needles: [String]) -> Bool {
        needles.contains { command.includes($0) || path.includes($0) }
    }

    // App bundles

    var appBundleName: String? {
        guard let range = rawPath.range(of: ".app/", options: .caseInsensitive) else { return nil }
        let bundle = (String(rawPath[..<range.lowerBound]) as NSString).lastPathComponent
        return bundle.isEmpty ? nil : bundle
    }

    var isAppMainBinary: Bool {
        guard let range = path.range(of: ".app/contents/macos/", options: .backwards) else { return false }
        let executable = path[range.upperBound...]
        guard !executable.isEmpty, !executable.contains("/") else { return false }
        let nested = [".app/contents/frameworks/", "/contents/helpers/", ".app/contents/library/", "/contents/xpcservices/"]
        return !nested.contains(where: path.includes) && !name.includes("helper")
    }

    var isEditorApp: Bool {
        let editors = ["xcode", "visual studio code", "code", "cursor", "windsurf", "zed", "sublime text", "textedit",
                       "pages", "numbers", "keynote", "microsoft word", "microsoft excel", "microsoft powerpoint",
                       "bbedit", "nova", "coteditor", "intellij idea", "pycharm", "webstorm", "goland", "rider",
                       "clion", "phpstorm", "rubymine", "android studio", "fleet", "photoshop", "illustrator",
                       "indesign", "affinity", "pixelmator", "sketch", "figma", "final cut pro", "logic pro",
                       "garageband", "blender", "davinci resolve", "obsidian", "scrivener", "ulysses", "notes",
                       "notion", "script editor", "libreoffice"]
        guard let app = appBundleName?.lowercased() else { return false }
        return editors.contains { app == $0 || app.hasPrefix($0 + " ") }
    }

    // Workloads

    var isContainerRuntime: Bool {
        named(["com.docker.backend", "com.docker.virtualization", "com.docker.vmnetd", "docker desktop", "colima",
               "limactl", "qemu-system-aarch64", "qemu-system-x86_64", "vfkit", "gvproxy", "orbstack", "podman"])
            || path.includes("/docker.app/contents/macos/") || path.includes("/orbstack.app/contents/macos/")
    }

    var isDataStore: Bool {
        if named(["postgres", "postmaster", "mysqld", "mariadbd", "mongod", "mongos", "redis-server", "valkey-server",
                  "keydb-server", "etcd", "influxd", "clickhouse", "clickhouse-server", "cockroach", "couchdb", "neo4j",
                  "minio", "meilisearch", "typesense-server", "qdrant", "surreal", "nats-server", "rabbitmq-server",
                  "arangod", "dgraph", "questdb", "tidb-server"]) {
            return true
        }
        if binary == "beam.smp" { return mentions(["rabbit", "couchdb"]) }
        if binary == "java" { return mentions(["org.elasticsearch", "opensearch", "kafka.kafka", "zookeeper", "cassandra", "neo4j", "solr"]) }
        return false
    }

    var isVersionControl: Bool {
        named(["git", "git-remote-https", "git-remote-http", "git-lfs", "hg", "svn", "jj"])
    }

    var isMutatingVersionControl: Bool {
        guard isVersionControl, let verb else { return false }
        return ["commit", "merge", "rebase", "pull", "fetch", "push", "checkout", "switch", "reset", "gc", "clone",
                "am", "cherry-pick", "revert", "stash", "repack", "prune", "worktree", "restore", "lfs", "submodule",
                "maintenance", "update", "up"].contains(verb)
    }

    var isPackageManager: Bool {
        let installVerbs: Set = ["install", "i", "ci", "add", "update", "upgrade", "up", "remove", "rm", "uninstall",
                                 "reinstall", "sync", "lock", "resolve", "bootstrap", "fetch", "download", "get", "require",
                                 "cleanup", "restore", "mod"]
        switch binary {
        case "npm", "pnpm", "bun", "cnpm":
            return verb.map(installVerbs.contains) ?? false
        case "yarn":
            return verb.map(installVerbs.contains) ?? true
        case "swift":
            return verb == "package" && args.contains { ["resolve", "update", "reset"].contains($0) }
        case "pip", "pip3", "uv", "poetry", "pipenv", "pdm", "conda", "mamba", "gem", "bundle", "bundler",
             "cargo", "go", "pod", "carthage", "composer", "mas", "port", "mix", "dotnet", "brew":
            return verb.map(installVerbs.contains) ?? false
        default:
            return name == "brew"
        }
    }

    var isScriptRunner: Bool {
        ["npm", "pnpm", "yarn", "bun", "npx", "sh", "bash", "zsh", "make"].contains(binary)
    }

    var isBuildTool: Bool {
        if named(["xcodebuild", "swift-build", "swift-frontend", "swiftc", "clang", "clang++", "ld", "ld64", "rustc",
                  "ninja", "make", "gmake", "bazel", "buck2", "esbuild", "tsc", "ibtool", "actool", "xcbbuildservice"]) {
            return !(binary == "tsc" && args.contains("--watch"))
        }
        let buildVerbs: Set = ["build", "test", "check", "compile", "assemble", "package", "bundle", "export"]
        switch binary {
        case "cargo", "go", "swift", "dotnet", "mvn", "gradle", "gradlew", "./gradlew", "turbo", "nx", "flutter", "xcrun":
            return verb.map(buildVerbs.contains) ?? false
        case "java":
            return mentions(["gradledaemon", "org.gradle", "maven"])
        default:
            return mentions(["next build", "vite build", "webpack --mode production", "nuxt build", "astro build"])
        }
    }

    var isDevServer: Bool {
        mentions(["vite", "next dev", "next-server", "nuxt", "astro dev", "webpack serve", "webpack-dev-server",
                  "react-scripts start", "rails s", "rails server", "puma", "unicorn", "uvicorn", "gunicorn",
                  "hypercorn", "flask run", "runserver", "php -s", "artisan serve", "hugo server", "jekyll serve",
                  "http-server", "live-server", "nodemon", "tsx watch", "ts-node-dev", "storybook", "expo start",
                  "remix dev", "vite-node", "parcel", "gatsby develop", "docusaurus start", "wrangler dev",
                  "netlify dev", "vercel dev", "dotnet watch", "phx.server", "bun --watch",
                  "bun run dev", "deno task dev", "npm run dev", "pnpm dev", "yarn dev", "npm start", "ng serve",
                  "python -m http.server", "python3 -m http.server", "jupyter", "streamlit run", "fastapi dev",
                  "manage.py runserver"])
    }

    var isModelRunner: Bool {
        named(["ollama", "llama-server", "llama-cli", "koboldcpp", "lm studio", "lms", "llamafile", "whisper-server"])
            || mentions(["mlx_lm.server", "vllm", "text-generation-launcher", "lm studio.app"])
    }

    // Supervisors

    var supervisorKind: KillSupervisorKind? {
        if mentions(["nodemon"]) { return .nodemon }
        if name.hasPrefix("pm2") || mentions(["pm2 v", "god daemon", "/pm2/"]) { return .pm2 }
        if mentions(["/forever/", "forever start", "foreverd"]) { return .forever }
        if named(["supervisord"]) { return .supervisord }
        if named(["watchexec"]) { return .watchexec }
        if named(["cargo-watch"]) || (binary == "cargo" && verb == "watch") { return .cargoWatch }
        if named(["air"]) { return .air }
        if (binary == "tsx" || command.includes("/tsx")) && args.contains("watch") { return .tsxWatch }
        if named(["entr"]) { return .entr }
        if named(["overmind"]) { return .overmind }
        return nil
    }

    var supervisorName: String? {
        switch supervisorKind {
        case .nodemon: "nodemon"
        case .pm2: "PM2"
        case .forever: "forever"
        case .tsxWatch: "tsx watch"
        case .cargoWatch: "cargo watch"
        case .some(let kind): kind.rawValue
        case .none: nil
        }
    }

    /// Background agents and daemons that launchd keeps alive; orphaned
    /// dev tools also have launchd as parent but nothing relaunches them.
    var isLaunchdManagedService: Bool {
        let managed = ["/system/", "/usr/libexec/", "/usr/sbin/", "/library/apple/", "/library/privilegedhelpertools/",
                       ".app/contents/library/loginitems/", "/contents/library/launchservices/", ".app/contents/helpers/",
                       "/library/application support/"]
        return managed.contains(where: path.hasPrefix) || managed.dropFirst(4).contains(where: path.includes)
    }
}

private extension String {
    /// A byte-wise substring test. Foundation's `contains` bridges on every
    /// call, which made scanning a large family's argv cost milliseconds.
    func includes(_ needle: String) -> Bool {
        var haystack = self
        var needle = needle
        return haystack.withUTF8 { text in
            needle.withUTF8 { pattern in
                guard let first = pattern.first else { return true }
                guard pattern.count <= text.count else { return false }
                for start in 0...(text.count - pattern.count) where text[start] == first {
                    if memcmp(text.baseAddress! + start, pattern.baseAddress!, pattern.count) == 0 { return true }
                }
                return false
            }
        }
    }
}
