import Darwin
import Foundation

public enum DevProcessKind: String, Codable, CaseIterable, Sendable {
    case nodeServer
    case electronApp
    case pythonService
    case dockerHelper
    case localModelRunner
    case javaServer
    case rubyServer
    case swiftBuild
    case goService
    case rustService
    case bunServer
    case denoServer
    case phpService
    case elixirService
    case dotnetService
    case cliTool
    case unknownHeavy

    public var label: String {
        switch self {
        case .nodeServer: "Node server"
        case .electronApp: "Electron app"
        case .pythonService: "Python service"
        case .dockerHelper: "Docker helper"
        case .localModelRunner: "Model runner"
        case .javaServer: "Java server"
        case .rubyServer: "Ruby server"
        case .swiftBuild: "Swift build"
        case .goService: "Go service"
        case .rustService: "Rust service"
        case .bunServer: "Bun server"
        case .denoServer: "Deno server"
        case .phpService: "PHP service"
        case .elixirService: "Elixir service"
        case .dotnetService: ".NET service"
        case .cliTool: "CLI tool"
        case .unknownHeavy: "Heavy process"
        }
    }
}

public struct DevClassification: Equatable, Sendable {
    public let kind: DevProcessKind
    public let confidence: Double
    public let reason: String

    public init(kind: DevProcessKind, confidence: Double, reason: String) {
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
    }
}

public struct DevProcessClassifier: Sendable {
    private let strongNames: Set<String>
    private let strongMarkers: [String]
    private let weakMarkers: [String]
    private let kindMarkers: KindMarkers

    public init(additionalCommandMarkers: [String] = []) {
        self.strongNames = [
            "node", "npm", "npx", "pnpm", "yarn", "bun", "deno",
            "python", "python3", "ruby", "rails", "java", "gradle", "mvn",
            "docker", "com.docker.backend", "colima", "qemu-system-aarch64",
            "ollama", "llama-server", "cargo", "rustc", "go", "air",
            "vite", "webpack", "next-server", "nodemon", "ts-node",
            "swift", "swift-frontend", "xcodebuild", "codex",
            "php", "php-fpm", "artisan", "frankenphp", "composer",
            "beam.smp", "elixir", "iex", "mix", "dotnet"
        ]
        self.strongMarkers = [
            "electron framework", "electron helper", "code helper", "cursor helper",
            "node_modules", "vite", "webpack", "next dev", "npm run",
            "pnpm", "yarn", "bun", "deno", "uvicorn", "gunicorn",
            "manage.py runserver", "rails server", "spring-boot", "gradle",
            "mvn", "docker compose", "colima", "ollama", "llama",
            "localai", "vllm", "mlx_lm", "jupyter", "cargo run", "cargo build",
            "go run", "go build", "bun dev", "bun run", "bun start",
            "deno run", "deno task", "deno serve", "deno test",
            "artisan serve", "artisan queue", "phpunit", "composer run", "swoole", "roadrunner", "composer.json",
            "mix phx.server", "mix test", "mix run", "elixir --sname", "mix.exs",
            "dotnet run", "dotnet watch", "dotnet test", "dotnet build",
            "watchexec", "nodemon", "tsx", "ts-node", "app-server",
            "/applications/codex.app", "/applications/cursor.app",
            "/applications/visual studio code.app"
        ] + additionalCommandMarkers.map { $0.lowercased() }
        self.weakMarkers = [
            "python", "ruby", "java", "docker", "go run", "pytest",
            "localhost", "server", "watch", "repl", "debug", "build",
            "swiftpm", ".build", "package.swift", "cargo", "rustc",
            "deno", "php", "composer", "mix", "dotnet"
        ]
        self.kindMarkers = KindMarkers()
    }

    public func confidence(for process: ProcessMetrics) -> Double {
        confidence(for: NormalizedProcessText(process))
    }

    private func confidence(for text: NormalizedProcessText) -> Double {
        var score = 0.0

        if strongNames.contains(text.name) {
            score += 0.75
        }
        if let executableName = text.executableName, strongNames.contains(executableName) {
            score += 0.55
        }
        if containsAny(strongMarkers, in: text.combined) {
            score += 0.65
        }
        if containsAny(weakMarkers, in: text.combined) {
            score += 0.25
        }
        if containsAnyPathRoot(in: text.path) {
            score += 0.12
        }

        return min(score, 1)
    }

    public func classification(for process: ProcessMetrics) -> DevClassification {
        let text = NormalizedProcessText(process)
        let confidence = confidence(for: text)

        let kind: DevProcessKind
        let reason: String
        if text.containsAny(kindMarkers.electron) {
            kind = .electronApp
            reason = "Electron helper/app signature"
        } else if text.name == "bun" || text.containsAny(kindMarkers.bun) {
            kind = .bunServer
            reason = "Bun server runtime/process"
        } else if text.name == "deno" || text.containsAny(kindMarkers.deno) {
            kind = .denoServer
            reason = "Deno server runtime/process"
        } else if kindMarkers.nodeNames.contains(text.name) || text.containsAny(kindMarkers.node) {
            kind = .nodeServer
            reason = "JavaScript dev server/runtime"
        } else if text.containsAny(kindMarkers.modelRunner) {
            kind = .localModelRunner
            reason = "Local model runner"
        } else if text.containsAny(kindMarkers.docker) {
            kind = .dockerHelper
            reason = "Container or VM helper"
        } else if text.name.hasPrefix("python") || text.containsAny(kindMarkers.python) {
            kind = .pythonService
            reason = "Python service or notebook"
        } else if kindMarkers.phpNames.contains(text.name) || text.containsAny(kindMarkers.php) {
            kind = .phpService
            reason = "PHP or Laravel developer service"
        } else if kindMarkers.elixirNames.contains(text.name) || text.containsAny(kindMarkers.elixir) {
            kind = .elixirService
            reason = "Elixir/Phoenix service or runner"
        } else if text.name == "dotnet" || text.containsAny(kindMarkers.dotnet) || cContains(text.path, "/bin/debug/") || cContains(text.path, "/bin/release/") {
            kind = .dotnetService
            reason = ".NET service or compiler runner"
        } else if text.name == "java" || text.containsAny(kindMarkers.java) {
            kind = .javaServer
            reason = "JVM build/server process"
        } else if text.name == "ruby" || text.containsAny(kindMarkers.ruby) {
            kind = .rubyServer
            reason = "Ruby/Rails service"
        } else if text.name == "swift" || text.name == "swift-frontend" || text.containsAny(kindMarkers.swift) {
            kind = .swiftBuild
            reason = "Swift build toolchain"
        } else if ["go", "air", "dlv"].contains(text.name) || text.containsAny(kindMarkers.go) || cContains(text.path, "/go-build/") || cContains(text.path, "/go/") || cContains(text.name, "-go-") || text.name.hasSuffix("-go") || text.name.hasPrefix("go-") {
            kind = .goService
            reason = "Go developer service or compiler"
        } else if text.name == "cargo" || text.name == "rustc" || cContains(text.path, "/target/debug/") || cContains(text.path, "/target/release/") || text.containsAny(kindMarkers.rust) || cContains(text.name, "-rust-") || cContains(text.name, "rust-") || text.name.hasSuffix("-rust") || text.name.hasPrefix("rust-") {
            kind = .rustService
            reason = "Rust developer service or compiler"
        } else if confidence >= 0.45 {
            kind = .cliTool
            reason = "Developer command markers"
        } else {
            kind = .unknownHeavy
            reason = "Heavy or watched process"
        }

        return DevClassification(kind: kind, confidence: confidence, reason: reason)
    }

    public func classification(for family: ProcessFamily) -> DevClassification {
        let root = classification(for: family.root)
        let memberClassifications = family.members.map(classification(for:))
        let strongest = memberClassifications.max { $0.confidence < $1.confidence } ?? root
        if strongest.kind == .unknownHeavy, let signal = family.hardwareSignals.first {
            return DevClassification(
                kind: .unknownHeavy,
                confidence: max(strongest.confidence, 0.30),
                reason: signal.reason
            )
        }
        if strongest.confidence > root.confidence {
            return strongest
        }
        return root
    }

    public func isDevProcess(_ process: ProcessMetrics) -> Bool {
        confidence(for: process) >= 0.45
    }

    private func containsAny(_ markers: [String], in text: String) -> Bool {
        cContainsAny(text, markers)
    }

    private func containsAnyPathRoot(in path: String) -> Bool {
        cContains(path, "/developer/") ||
            cContains(path, "/usr/local/") ||
            cContains(path, "/opt/homebrew/")
    }
}

private struct NormalizedProcessText {
    let name: String
    let path: String
    let command: String
    let combined: String
    let executableName: String?

    init(_ process: ProcessMetrics) {
        name = process.name.lowercased()
        path = process.executablePath.lowercased()
        command = process.commandLine.lowercased()
        combined = name + " " + path + " " + command
        if let slash = path.lastIndex(of: "/") {
            executableName = String(path[path.index(after: slash)...])
        } else {
            executableName = path.isEmpty ? nil : path
        }
    }

    func containsAny(_ markers: [String]) -> Bool {
        cContainsAny(combined, markers)
    }
}

private struct KindMarkers: Sendable {
    let nodeNames: Set<String> = ["node", "npm", "npx", "pnpm", "yarn"]
    let phpNames: Set<String> = ["php", "php-fpm", "artisan", "frankenphp", "composer"]
    let elixirNames: Set<String> = ["beam.smp", "elixir", "iex", "mix"]

    let electron = ["electron", "code helper", "cursor helper"]
    let bun = ["bun run", "bun start", "bun dev"]
    let deno = ["deno run", "deno task", "deno serve"]
    let node = ["node_modules", "vite", "next dev"]
    let modelRunner = ["ollama", "llama", "vllm", "mlx_lm", "localai"]
    let docker = ["docker", "colima", "qemu-system"]
    let python = ["uvicorn", "gunicorn", "manage.py runserver", "jupyter"]
    let php = ["artisan serve", "artisan queue", "phpunit", "composer run", "composer.json", "swoole", "roadrunner"]
    let elixir = ["mix phx.server", "mix test", "mix run", "mix.exs"]
    let dotnet = ["dotnet run", "dotnet watch", "dotnet test", "dotnet build"]
    let java = ["gradle", "mvn", "spring-boot"]
    let ruby = ["rails server"]
    let swift = ["xcodebuild", "swiftpm"]
    let go = ["go run", "go build"]
    let rust = ["cargo run"]
}

private func cContains(_ haystack: String, _ needle: String) -> Bool {
    guard !needle.isEmpty, !haystack.isEmpty else {
        return false
    }
    return haystack.withCString { haystackPointer in
        needle.withCString { needlePointer in
            strstr(haystackPointer, needlePointer) != nil
        }
    }
}

private func cContainsAny(_ haystack: String, _ needles: [String]) -> Bool {
    guard !haystack.isEmpty, !needles.isEmpty else {
        return false
    }
    return haystack.withCString { haystackPointer in
        for needle in needles where !needle.isEmpty {
            let found = needle.withCString { needlePointer in
                strstr(haystackPointer, needlePointer) != nil
            }
            if found {
                return true
            }
        }
        return false
    }
}
