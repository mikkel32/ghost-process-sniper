import Darwin
import Foundation

public enum DevProcessKind: String, Codable, CaseIterable, Sendable {
    case nodeServer
    case electronApp
    case pythonService
    /// Stored as "dockerHelper", its name before it covered every container
    /// and VM runtime, so persisted kinds and kill learning keep matching.
    case containerRuntime = "dockerHelper"
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
    case languageServer
    case testRunner
    case buildWatcher
    case dataStore
    case simulator
    case ideService
    case editorApp
    case cliTool
    case unknownHeavy

    /// The old name of `containerRuntime`.
    public static var dockerHelper: DevProcessKind { .containerRuntime }

    public var label: String {
        switch self {
        case .nodeServer: "Node server"
        case .electronApp: "Electron app"
        case .pythonService: "Python service"
        case .containerRuntime: "Container runtime"
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
        case .languageServer: "Language server"
        case .testRunner: "Test runner"
        case .buildWatcher: "Build watcher"
        case .dataStore: "Database"
        case .simulator: "Simulator"
        case .ideService: "IDE service"
        case .editorApp: "Editor"
        case .cliTool: "CLI tool"
        case .unknownHeavy: "Heavy process"
        }
    }

    /// Long-running helpers that serve an editor or a project and that a
    /// family boundary should keep separate from what launched them.
    public var isServiceKind: Bool {
        switch self {
        case .languageServer, .dataStore, .localModelRunner, .testRunner, .buildWatcher: true
        default: false
        }
    }
}

public struct DevClassification: Equatable, Sendable {
    public let kind: DevProcessKind
    public let confidence: Double
    public let reason: String
    /// What the process is for beyond its kind: dev server, build or test
    /// work, long-lived service, notebook kernel.
    public let traits: WorkloadTraits

    public init(kind: DevProcessKind, confidence: Double, reason: String, traits: WorkloadTraits = []) {
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
        self.traits = traits
    }

    /// Compiles, bundles or tests, and ends by itself: what it takes, it
    /// gives back when it exits, so its climb is work, not a leak. A watcher
    /// stays up and can leak like any service.
    public var isOneShotBuild: Bool {
        traits.contains(.buildOrTest) && !traits.contains(.longLived)
    }

    /// Picks the representative classification of a group: kinds that own
    /// whole process trees outrank generic CLI hits of equal confidence.
    var groupingPriority: Double {
        let kindBoost: Double = switch kind {
        case .unknownHeavy:
            0
        case .cliTool:
            0.03
        case .electronApp, .localModelRunner, .containerRuntime, .editorApp:
            0.2
        default:
            0.12
        }
        return confidence + kindBoost
    }
}

public struct DevProcessClassifier: Sendable {
    private let strongNames: Set<String>
    private let strongMarkers: [String]
    private let weakMarkers: [String]
    /// User-supplied markers keep plain substring matching.
    private let customMarkers: [String]

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
        // Single words match whole words only; phrases and paths match as
        // substrings of the command and path.
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
        ]
        self.weakMarkers = [
            "python", "ruby", "java", "docker", "go run", "pytest",
            "localhost", "server", "watch", "repl", "debug", "build",
            "swiftpm", ".build", "package.swift", "cargo", "rustc",
            "deno", "php", "composer", "mix", "dotnet"
        ]
        self.customMarkers = additionalCommandMarkers.map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    public func confidence(for process: ProcessMetrics) -> Double {
        confidence(for: WorkloadTokens(process))
    }

    private func confidence(for tokens: WorkloadTokens) -> Double {
        var score = 0.0

        if strongNames.contains(tokens.name) {
            score += 0.75
        }
        if !tokens.executable.isEmpty, strongNames.contains(tokens.executable) {
            score += 0.55
        }
        if tokens.mentions(strongMarkers) || customMarkers.contains(where: { tokens.lowerCommand.contains($0) || tokens.lowerPath.contains($0) }) {
            score += 0.65
        }
        if tokens.mentions(weakMarkers) {
            score += 0.25
        }
        // A binary running out of a project's build output is dev work.
        if tokens.mentions(Self.buildOutputDirectories) {
            score += 0.4
        }
        if tokens.pathComponents.contains("developer") || tokens.lowerPath.hasPrefix("/usr/local/") ||
            tokens.lowerPath.hasPrefix("/opt/homebrew/") {
            score += 0.12
        }

        return min(score, 1)
    }

    public func classification(for process: ProcessMetrics) -> DevClassification {
        classification(for: WorkloadTokens(process))
    }

    public func classification(for tokens: WorkloadTokens) -> DevClassification {
        let confidence = confidence(for: tokens)
        var traits: WorkloadTraits = []
        if WorkloadCatalog.isDevServer(tokens) {
            traits.formUnion([.devServer, .longLived])
        }
        if WorkloadCatalog.isBuildOrTest(tokens) {
            traits.insert(.buildOrTest)
        }
        if let match = WorkloadCatalog.match(tokens) {
            return DevClassification(
                kind: match.kind,
                confidence: max(confidence, match.confidence),
                reason: match.reason,
                traits: traits.union(match.traits)
            )
        }
        let (kind, reason) = languageKind(tokens, confidence: confidence, traits: &traits)
        return DevClassification(kind: kind, confidence: confidence, reason: reason, traits: traits)
    }

    private func languageKind(
        _ tokens: WorkloadTokens,
        confidence: Double,
        traits: inout WorkloadTraits
    ) -> (DevProcessKind, String) {
        let name = tokens.name
        if tokens.mentions(["electron framework", "electron helper", "code helper", "cursor helper"]) ||
            tokens.named(["electron"]) || tokens.pathComponents.contains("electron.app") {
            return (.electronApp, "Electron helper/app signature")
        }
        if tokens.named(["bun", "bunx"]) || tokens.mentions(["bun run", "bun start", "bun dev"]) {
            return (.bunServer, "Bun server runtime/process")
        }
        if tokens.named(["deno"]) || tokens.mentions(["deno run", "deno task", "deno serve"]) {
            return (.denoServer, "Deno server runtime/process")
        }
        if tokens.named(Self.nodeNames) || tokens.pathComponents.contains("node_modules") || tokens.mentions(["next dev"]) {
            return (.nodeServer, traits.contains(.devServer) ? "JavaScript dev server" : "Node.js runtime or tool")
        }
        if name.hasPrefix("python") || tokens.argv0.hasPrefix("python") || tokens.named(Self.pythonNames) ||
            tokens.mentions(["manage.py runserver"]) {
            if tokens.words.contains(where: { $0.hasPrefix("ipykernel") }) || tokens.named(["jupyter", "jupyter-lab", "jupyter-notebook"]) {
                traits.formUnion([.notebookKernel, .longLived])
                return (.pythonService, "Python notebook kernel")
            }
            return (.pythonService, "Python service or notebook")
        }
        if tokens.named(Self.phpNames) ||
            tokens.mentions(["artisan serve", "artisan queue", "composer run", "composer.json", "swoole", "roadrunner"]) {
            return (.phpService, "PHP or Laravel developer service")
        }
        if tokens.named(Self.elixirNames) || tokens.mentions(["mix phx.server", "mix test", "mix run", "mix.exs"]) {
            return (.elixirService, "Elixir/Phoenix service or runner")
        }
        if tokens.named(["dotnet"]) || tokens.mentions(["dotnet run", "dotnet watch", "dotnet test", "dotnet build", "/bin/debug/", "/bin/release/"]) {
            return (.dotnetService, ".NET service or compiler runner")
        }
        if tokens.named(["java", "gradle", "gradlew", "mvn", "mvnw"]) || tokens.mentions(["spring-boot"]) {
            return (.javaServer, "JVM build/server process")
        }
        if tokens.named(["ruby", "rails", "puma", "unicorn"]) || tokens.mentions(["rails server"]) {
            return (.rubyServer, "Ruby/Rails service")
        }
        if tokens.named(["swift"]) || tokens.pathComponents.contains("swiftpm") {
            return (.swiftBuild, "Swift build toolchain")
        }
        if tokens.named(["go", "air", "dlv"]) || tokens.mentions(["go run", "go build"]) ||
            tokens.pathComponents.contains("go-build") || tokens.pathComponents.contains("go") ||
            name.contains("-go-") || name.hasSuffix("-go") || name.hasPrefix("go-") {
            return (.goService, "Go developer service or compiler")
        }
        if tokens.named(["cargo", "rustc"]) || tokens.mentions(["/target/debug/", "/target/release/", "cargo run"]) ||
            name.contains("-rust-") || name.hasPrefix("rust-") || name.hasSuffix("-rust") {
            return (.rustService, "Rust developer service or compiler")
        }
        if confidence >= 0.45 {
            return (.cliTool, "Developer command markers")
        }
        return (.unknownHeavy, "Heavy or watched process")
    }

    public func classification(for family: ProcessFamily) -> DevClassification {
        let root = classification(for: family.root)
        let memberClassifications = family.members.map { classification(for: $0) }
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

    private static let nodeNames: Set<String> = [
        "node", "nodejs", "npm", "npx", "pnpm", "yarn", "nodemon", "ts-node", "tsx", "next-server", "next",
        "vite", "webpack", "webpack-dev-server",
    ]
    private static let pythonNames: Set<String> = [
        "uvicorn", "gunicorn", "hypercorn", "jupyter", "jupyter-lab", "jupyter-notebook", "ipython", "celery",
        "flask", "django-admin", "streamlit", "gradio",
    ]
    private static let buildOutputDirectories = [
        "/target/debug/", "/target/release/", "/.build/debug/", "/.build/release/", "/bin/debug/", "/bin/release/",
        "/deriveddata/",
    ]
    private static let phpNames: Set<String> = ["php", "php-fpm", "artisan", "frankenphp", "composer"]
    private static let elixirNames: Set<String> = ["beam.smp", "elixir", "iex", "mix"]
}
