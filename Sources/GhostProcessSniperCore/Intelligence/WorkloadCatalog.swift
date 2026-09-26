import Darwin
import Foundation

/// The words a process is known by, cut at real boundaries so rules match
/// whole tokens: "bun" never matches "bundle" and "vite" never "Invites".
public struct WorkloadTokens: Sendable {
    /// Lowercased process name.
    public let name: String
    /// Basename of the command's first word (the executable path when the
    /// command starts with it, so paths with spaces stay whole).
    public let argv0: String
    /// Basename of the executable path.
    public let executable: String
    /// Outermost .app bundle name, without the extension: the product a
    /// helper belongs to.
    public let appBundle: String?
    /// Innermost .app bundle name: the app this binary launches as.
    public let innermostBundle: String?
    /// For interpreters: the script or module stem, e.g. "vite", "tsserver",
    /// "uvicorn", "ipykernel_launcher". `node_modules/.bin/X` reduces to X.
    public let script: String?
    /// The node_modules package the script lives in, e.g. "jest-worker".
    public let package: String?
    /// The script or module argument as given, lowercased.
    public let scriptPath: String?
    /// Lowercased arguments after argv0, at most 24.
    public let arguments: [String]
    /// Every component of the executable and script paths.
    public let pathComponents: Set<String>
    /// Every whole word in the name, path and arguments: split on spaces,
    /// "/", "=" and ":".
    public let words: Set<String>
    public let lowerCommand: String
    public let lowerPath: String
    /// True for the main executable of an .app bundle.
    public let isAppMainBinary: Bool

    /// The words that say what the process is.
    public var identities: [String] {
        [name, argv0, executable, script, package].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// The first argument that is not a flag, e.g. `test` in `cargo --quiet test`.
    public var verb: String? {
        arguments.first { !$0.hasPrefix("-") }
    }

    public init(_ process: ProcessMetrics) {
        self.init(name: process.name, path: process.executablePath, command: process.commandLine)
    }

    public init(name: String, path: String, command: String) {
        self.name = name.lowercased()
        let lowerPath = path.lowercased()
        self.lowerPath = lowerPath
        lowerCommand = command.lowercased()
        executable = Self.basename(lowerPath)
        isAppMainBinary = LaunchOrigin.isAppMainBinary(path: path, name: name)
        appBundle = lowerPath.range(of: ".app/").flatMap { Self.bundleName(lowerPath[..<$0.lowerBound]) }
        innermostBundle = lowerPath.range(of: ".app/", options: .backwards).flatMap { Self.bundleName(lowerPath[..<$0.lowerBound]) }

        let rest: Substring
        let first: String
        if !lowerPath.isEmpty, lowerCommand.hasPrefix(lowerPath) {
            first = lowerPath
            rest = lowerCommand.dropFirst(lowerPath.count)
        } else {
            let trimmed = lowerCommand.drop { $0.isWhitespace }
            let end = trimmed.firstIndex { $0.isWhitespace } ?? trimmed.endIndex
            first = String(trimmed[..<end])
            rest = trimmed[end...]
        }
        argv0 = Self.basename(first.hasSuffix(":") ? String(first.dropLast()) : first).ifEmpty(self.name)
        arguments = rest.split(whereSeparator: \.isWhitespace).prefix(24).map(String.init)

        let scriptPath = Self.scriptPath(interpreter: argv0, arguments: arguments)
        self.scriptPath = scriptPath
        script = scriptPath.map(Self.scriptStem)
        package = scriptPath.flatMap(Self.nodePackage)

        var components = Set(lowerPath.split(separator: "/").map(String.init))
        if let scriptPath {
            components.formUnion(scriptPath.split(separator: "/").map(String.init))
        }
        pathComponents = components

        var words = components
        words.insert(self.name)
        words.insert(argv0)
        for argument in arguments {
            for word in argument.split(whereSeparator: { $0 == "/" || $0 == "=" || $0 == ":" || $0 == "," }) {
                words.insert(String(word))
            }
            // A script argument also names its stem: "server.js" says "server".
            let stem = Self.scriptStem(argument)
            if stem.count < Self.basename(argument).count {
                words.insert(stem)
            }
        }
        if let script { words.insert(script) }
        if let package { words.insert(package) }
        self.words = words
    }

    public func named(_ candidates: Set<String>) -> Bool {
        identities.contains(where: candidates.contains)
    }

    /// Multi-word command markers ("next dev", "npm run") keep substring
    /// matching; single words must be whole words.
    public func mentions(_ markers: [String]) -> Bool {
        markers.contains { marker in
            let isPhrase = marker.utf8.contains { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "/") }
            return isPhrase ? Self.contains(lowerCommand, marker) || Self.contains(lowerPath, marker) : words.contains(marker)
        }
    }

    /// A byte search: Foundation's substring search costs far more, and the
    /// catalog runs dozens of them per new process.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        return haystack.withCString { text in
            needle.withCString { strstr(text, $0) != nil }
        }
    }

    // MARK: - Parsing

    private static let interpreters: Set<String> = [
        "node", "nodejs", "bun", "bunx", "deno", "ruby", "java", "php", "perl", "tsx", "ts-node", "npx", "pnpx",
    ]
    private static let subcommands: Set<String> = ["run", "task", "serve", "test", "x", "exec"]

    static func isInterpreter(_ argv0: String) -> Bool {
        interpreters.contains(argv0) || argv0.hasPrefix("python")
    }

    private static func scriptPath(interpreter: String, arguments: [String]) -> String? {
        guard isInterpreter(interpreter) else { return nil }
        var index = arguments.startIndex
        var skippedSubcommand = false
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "-m" || argument == "-jar" {
                return index + 1 < arguments.endIndex ? arguments[index + 1] : nil
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            if (interpreter == "bun" || interpreter == "deno"), !skippedSubcommand, subcommands.contains(argument) {
                skippedSubcommand = true
                index += 1
                continue
            }
            return argument
        }
        return nil
    }

    private static let scriptExtensions = [".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".py", ".rb", ".jar", ".php", ".pl"]

    private static func scriptStem(_ path: String) -> String {
        var stem = basename(path)
        for suffix in scriptExtensions where stem.hasSuffix(suffix) && stem.count > suffix.count {
            stem.removeLast(suffix.count)
            break
        }
        return stem
    }

    private static func nodePackage(_ path: String) -> String? {
        guard let range = path.range(of: "node_modules/", options: .backwards) else { return nil }
        let parts = path[range.upperBound...].split(separator: "/")
        guard let first = parts.first, first != ".bin" else { return nil }
        if first.hasPrefix("@"), parts.count > 1 {
            return "\(first)/\(parts[1])"
        }
        return String(first)
    }

    private static func bundleName(_ prefix: Substring) -> String? {
        let name = basename(String(prefix))
        return name.isEmpty ? nil : name
    }

    static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

/// What a process is for, beyond its language.
public struct WorkloadTraits: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Serves requests while developing (vite, uvicorn, rails server).
    public static let devServer = WorkloadTraits(rawValue: 1 << 0)
    /// Compiles, bundles or tests: heavy CPU is expected and ends by itself.
    public static let buildOrTest = WorkloadTraits(rawValue: 1 << 1)
    /// Meant to stay up for the whole session.
    public static let longLived = WorkloadTraits(rawValue: 1 << 2)
    /// A Jupyter or IPython kernel.
    public static let notebookKernel = WorkloadTraits(rawValue: 1 << 3)
}

/// One catalog hit: the kind, how sure, why, and what the process is for.
public struct WorkloadMatch: Equatable, Sendable {
    public let kind: DevProcessKind
    /// The least dev confidence this match deserves.
    public let confidence: Double
    public let reason: String
    public let traits: WorkloadTraits
}

/// Real developer tools by exact name, path component or bundle, shared by
/// the classifier and the sampler's rich-read hints.
public enum WorkloadCatalog {
    /// Process names (as the kernel reports them, lowercased) that earn a
    /// rich read before they cross any threshold, so a quiet language server
    /// or database can be measured and scored at all.
    public static let probeHintNames: Set<String> = [
        "node", "npm", "pnpm", "yarn", "bun", "vite", "deno", "python", "python3",
        "ruby", "rails", "java", "gradle", "mvn", "docker", "com.docker.backend",
        "colima", "ollama", "swift", "swift-frontend", "swift-build", "xcodebuild",
        "electron", "uvicorn", "gunicorn", "webpack", "next",
        "rust-analyzer", "gopls", "clangd", "sourcekit-lsp", "sourcekitservice", "tsserver",
        "postgres", "redis-server", "mysqld", "mongod", "esbuild", "jest", "vitest",
        "llama-server", "com.docker.virtualization", "orbstack helper", "orbstack", "launchd_sim",
        "cargo", "rustc", "go", "dotnet", "beam.smp", "php", "xcbbuildservice", "limactl", "qemu-system-aarch64",
    ]

    static let languageServers: Set<String> = [
        "rust-analyzer", "gopls", "clangd", "sourcekit-lsp", "tsserver", "typescript-language-server", "pyright",
        "pyright-langserver", "basedpyright", "basedpyright-langserver", "pylsp", "jedi-language-server", "ruff-lsp",
        "lua-language-server", "solargraph", "ruby-lsp", "jdtls", "kotlin-language-server", "elixir-ls",
        "haskell-language-server", "haskell-language-server-wrapper", "zls", "terraform-ls", "yaml-language-server",
        "omnisharp", "csharp-ls", "intelephense", "texlab", "marksman", "taplo", "bash-language-server", "metals",
        "ocamllsp", "svelteserver", "vue-language-server", "tailwindcss-language-server", "copilot-language-server",
        "eslintserver", "jsonservermain", "cssservermain", "htmlservermain", "vscode-json-language-server",
        "vscode-css-language-server", "vscode-html-language-server", "vscode-eslint-language-server",
        "dart_language_server", "kotlin-lsp", "harper-ls", "biome", "deno-lsp",
    ]

    static let ideServices: Set<String> = [
        "sourcekitservice", "com.apple.dt.skagent", "ibagent-ios", "ibdesignablesagent-ios", "xcpreviewagent",
        "previewshost", "xcodepreviews", "fsnotifier", "com.apple.dt.instruments.dtsymbolicationservice",
    ]

    static let editorBundles = [
        "xcode", "visual studio code", "cursor", "windsurf", "zed", "sublime text", "nova", "bbedit", "fleet",
        "intellij idea", "pycharm", "webstorm", "goland", "rider", "clion", "phpstorm", "rubymine", "android studio",
        "vscodium", "codex", "positron", "trae", "kiro", "void",
    ]

    static let simulators: Set<String> = [
        "launchd_sim", "simctl", "simulatortrampoline", "com.apple.coresimulator.coresimulatorservice",
        "simulator", "simdiskimaged",
    ]

    /// KillRiskAssessor's data-store names.
    static let dataStores: Set<String> = [
        "postgres", "postmaster", "mysqld", "mariadbd", "mongod", "mongos", "redis-server", "valkey-server",
        "keydb-server", "etcd", "influxd", "clickhouse", "clickhouse-server", "cockroach", "couchdb", "neo4j",
        "minio", "meilisearch", "typesense-server", "qdrant", "surreal", "nats-server", "rabbitmq-server",
        "arangod", "dgraph", "questdb", "tidb-server", "memcached", "elasticsearch", "opensearch",
    ]

    /// KillRiskAssessor's container and VM runtimes.
    static let containerRuntimes: Set<String> = [
        "com.docker.backend", "com.docker.virtualization", "com.docker.vmnetd", "com.docker.build", "docker desktop",
        "colima", "limactl", "qemu-system-aarch64", "qemu-system-x86_64", "vfkit", "gvproxy", "orbstack",
        "orbstack helper", "podman", "podman-machine", "docker", "docker-compose", "containerd", "buildkitd",
        "krunkit", "lima", "rancher desktop",
    ]
    static let containerBundles: Set<String> = ["docker", "orbstack", "podman desktop", "rancher desktop"]

    /// KillRiskAssessor's model runners.
    static let modelRunners: Set<String> = [
        "ollama", "llama-server", "llama-cli", "koboldcpp", "lm studio", "lms", "llamafile", "whisper-server",
        "localai", "vllm", "text-generation-launcher", "mlx_lm.server", "mlx_lm", "lmstudio", "llama.cpp",
    ]

    static let testRunners: Set<String> = [
        "jest", "vitest", "mocha", "ava", "karma", "cypress", "pytest", "py.test", "rspec", "phpunit", "pest",
        "xctest", "swiftpm-testing-helper", "jest-worker", "cargo-nextest", "gotestsum",
    ]

    static let buildWatchers: Set<String> = [
        "esbuild", "watchexec", "cargo-watch", "fswatch", "entr", "ibazel", "watchman",
    ]
    /// Tools that watch only with a watch flag.
    static let watchableBuilders: Set<String> = ["tsc", "webpack", "rollup", "sass", "tailwindcss", "babel", "swc", "tsup"]

    static let swiftTools: Set<String> = [
        "swift-build", "swift-frontend", "swiftc", "swift-driver", "xcodebuild", "xcbbuildservice", "swift-test",
        "swift-run", "swift-package", "swift-autolink-extract",
    ]

    static let compilers: Set<String> = [
        "clang", "clang++", "cc", "c++", "gcc", "g++", "ld", "ld64", "ld-prime", "ninja", "make", "gmake", "bazel",
        "buck2", "cmake", "ibtool", "actool", "lld", "swift-api-digester",
    ]

    /// KillRiskAssessor's dev-server markers.
    static let devServerMarkers = [
        "vite", "next dev", "next-server", "nuxt", "astro dev", "webpack serve", "webpack-dev-server",
        "react-scripts start", "rails s", "rails server", "puma", "unicorn", "uvicorn", "gunicorn",
        "hypercorn", "flask run", "runserver", "php -s", "artisan serve", "hugo server", "jekyll serve",
        "http-server", "live-server", "nodemon", "tsx watch", "ts-node-dev", "storybook", "expo start",
        "remix dev", "vite-node", "parcel", "gatsby develop", "docusaurus start", "wrangler dev",
        "netlify dev", "vercel dev", "dotnet watch", "phx.server", "bun --watch",
        "bun run dev", "deno task dev", "npm run dev", "pnpm dev", "yarn dev", "npm start", "ng serve",
    ]

    static let buildVerbs: Set<String> = ["build", "compile", "assemble", "bundle", "archive", "install", "check"]
    static let testVerbs: Set<String> = ["test", "nextest"]
    /// Toolchain verbs that lint, document, benchmark or generate code.
    static let checkVerbs: Set<String> = ["clippy", "doc", "bench", "fmt", "vet", "generate"]
    /// Package scripts that build, test, lint or typecheck.
    static let buildScripts: Set<String> = ["build", "test", "lint", "typecheck", "type-check", "check"]

    /// Typecheckers, linters, formatters and bundlers: one-shot whole-project
    /// work that holds a core for minutes, unless it watches or serves.
    static let oneShotCheckers: Set<String> = [
        "tsc", "vue-tsc", "eslint", "prettier", "biome", "webpack", "rollup", "esbuild",
        "mypy", "pyright", "ruff", "pylint", "black",
    ]
    private static let servingArguments: Set<String> = ["--watch", "-w", "watch", "serve", "server", "--stdio", "--lsp", "lsp", "lsp-proxy"]

    /// The catalog's verdict for kinds a language alone cannot name, or nil.
    public static func match(_ tokens: WorkloadTokens) -> WorkloadMatch? {
        if tokens.isAppMainBinary, let app = tokens.innermostBundle, isEditorBundle(app) {
            return WorkloadMatch(kind: .editorApp, confidence: 0.8, reason: "Editor or IDE app", traits: .longLived)
        }
        if tokens.named(simulators) || tokens.pathComponents.contains(where: { $0.hasSuffix(".simruntime") }) ||
            (tokens.isAppMainBinary && tokens.innermostBundle == "simulator") {
            return WorkloadMatch(kind: .simulator, confidence: 0.7, reason: "iOS Simulator runtime", traits: .longLived)
        }
        if tokens.named(ideServices) || (tokens.appBundle == "xcode" && tokens.pathComponents.contains("xpcservices")) {
            return WorkloadMatch(kind: .ideService, confidence: 0.8, reason: "IDE indexing or preview service", traits: .longLived)
        }
        if isLanguageServer(tokens) {
            return WorkloadMatch(kind: .languageServer, confidence: 0.9, reason: "Language server", traits: .longLived)
        }
        if isTestRunner(tokens) {
            return WorkloadMatch(kind: .testRunner, confidence: 0.9, reason: "Test runner", traits: .buildOrTest)
        }
        if isBuildWatcher(tokens) {
            return WorkloadMatch(kind: .buildWatcher, confidence: 0.85, reason: "Build watcher", traits: [.buildOrTest, .longLived])
        }
        if isDataStore(tokens) {
            return WorkloadMatch(kind: .dataStore, confidence: 0.8, reason: "Database or data store", traits: .longLived)
        }
        if isContainerRuntime(tokens) {
            return WorkloadMatch(kind: .containerRuntime, confidence: 0.85, reason: "Container or VM runtime", traits: .longLived)
        }
        if isModelRunner(tokens) {
            return WorkloadMatch(kind: .localModelRunner, confidence: 0.9, reason: "Local model runner", traits: .longLived)
        }
        if tokens.named(swiftTools) || (tokens.argv0 == "swift" && tokens.verb.map { ["build", "test", "run", "package"].contains($0) } == true) {
            return WorkloadMatch(kind: .swiftBuild, confidence: 0.95, reason: "Swift build toolchain", traits: .buildOrTest)
        }
        if tokens.named(compilers) {
            return WorkloadMatch(kind: .cliTool, confidence: 0.6, reason: "Compiler or build tool", traits: .buildOrTest)
        }
        return nil
    }

    /// Build or test work, from the verbs of any toolchain: CPU bursts here
    /// are expected and end by themselves.
    public static func isBuildOrTest(_ tokens: WorkloadTokens) -> Bool {
        if tokens.named(swiftTools) || tokens.named(compilers) || tokens.named(testRunners) || isOneShotChecker(tokens) {
            return true
        }
        guard let verb = tokens.verb else { return false }
        switch tokens.argv0 {
        case "cargo", "go", "swift", "dotnet", "mvn", "gradle", "gradlew", "turbo", "nx", "flutter", "xcrun", "mix", "zig":
            return buildVerbs.contains(verb) || testVerbs.contains(verb) || checkVerbs.contains(verb)
        case "npm", "pnpm", "yarn", "bun", "deno":
            let script = verb == "run" ? tokens.arguments.dropFirst().first { !$0.hasPrefix("-") } : verb
            return script.map { script in
                buildScripts.contains(script) || buildScripts.contains { script.hasPrefix($0 + ":") }
            } ?? false
        default:
            return tokens.mentions(["next build", "vite build", "webpack --mode production", "nuxt build", "astro build"])
        }
    }

    /// By what the process runs, not the package it comes from: a language
    /// server shipped in the pyright package is not a one-shot check.
    private static func isOneShotChecker(_ tokens: WorkloadTokens) -> Bool {
        let runs = [tokens.name, tokens.argv0, tokens.executable, tokens.script ?? ""]
        guard runs.contains(where: oneShotCheckers.contains) else { return false }
        return !tokens.arguments.contains { servingArguments.contains($0) || $0.hasPrefix("--watch=") }
    }

    public static func isDevServer(_ tokens: WorkloadTokens) -> Bool {
        tokens.mentions(devServerMarkers)
    }

    static func isEditorBundle(_ app: String) -> Bool {
        editorBundles.contains { app == $0 || app.hasPrefix($0 + " ") }
    }

    private static func isLanguageServer(_ tokens: WorkloadTokens) -> Bool {
        if tokens.named(languageServers) {
            return true
        }
        return tokens.identities.contains { identity in
            identity.hasSuffix("-lsp") || identity.hasSuffix("-language-server") || identity.hasSuffix("-languageserver") ||
                identity.hasSuffix("-langserver") || identity == "pylsp"
        }
    }

    private static func isTestRunner(_ tokens: WorkloadTokens) -> Bool {
        if tokens.named(testRunners) {
            return true
        }
        guard let verb = tokens.verb else { return false }
        switch tokens.argv0 {
        case "cargo", "go", "dotnet", "mix", "swift", "deno", "bun", "npm", "pnpm", "yarn", "zig":
            return testVerbs.contains(verb) || (verb == "run" && tokens.arguments.dropFirst().first == "test")
        case "xcodebuild":
            return tokens.arguments.contains("test")
        default:
            return false
        }
    }

    private static func isBuildWatcher(_ tokens: WorkloadTokens) -> Bool {
        if tokens.named(buildWatchers) {
            return true
        }
        let watching = tokens.arguments.contains { $0 == "--watch" || $0 == "-w" || $0 == "watch" || $0.hasPrefix("--watch=") }
        return watching && tokens.named(watchableBuilders)
    }

    private static func isDataStore(_ tokens: WorkloadTokens) -> Bool {
        if tokens.named(dataStores) {
            return true
        }
        if tokens.argv0 == "beam.smp" || tokens.name == "beam.smp" {
            return tokens.mentions(["rabbit", "couchdb"])
        }
        if tokens.argv0 == "java" || tokens.name == "java" {
            return tokens.mentions(["org.elasticsearch.bootstrap.elasticsearch", "org.opensearch.bootstrap.opensearch", "kafka.kafka",
                                    "org.apache.zookeeper.server.quorum.quorumpeermain", "org.apache.cassandra.service.cassandradaemon", "org.neo4j", "solr"])
        }
        return false
    }

    private static func isContainerRuntime(_ tokens: WorkloadTokens) -> Bool {
        if tokens.named(containerRuntimes) || tokens.identities.contains(where: { $0.hasPrefix("com.docker.") || $0.hasPrefix("qemu-system-") }) {
            return true
        }
        return tokens.appBundle.map(containerBundles.contains) ?? false
    }

    private static func isModelRunner(_ tokens: WorkloadTokens) -> Bool {
        if tokens.named(modelRunners) || tokens.appBundle == "lm studio" || tokens.identities.contains(where: { $0.hasSuffix(".llamafile") }) {
            return true
        }
        return tokens.script.map { $0.hasPrefix("mlx_lm") || $0.hasPrefix("vllm") || $0.hasPrefix("llama_cpp") } ?? false
    }
}
