import Foundation
import XCTest
@testable import GhostProcessSniperCore

/// Real names, paths and argv from developer Macs. `dev` is whether the
/// process clears the Dev-mode cutoff (0.35) on its own.
final class ClassifierCatalogTests: XCTestCase {
    private struct Row {
        let name: String
        let path: String
        let command: String
        let kind: DevProcessKind
        let dev: Bool
        let line: UInt

        init(_ name: String, _ path: String, _ command: String? = nil, _ kind: DevProcessKind, dev: Bool = true, line: UInt = #line) {
            self.name = name
            self.path = path
            self.command = command ?? path
            self.kind = kind
            self.dev = dev
            self.line = line
        }
    }

    private static let xcode = "/Applications/Xcode.app/Contents"
    private static let toolchain = "\(xcode)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    private static let code = "/Applications/Visual Studio Code.app/Contents"

    private let rows: [Row] = [
        // Editors and IDE services.
        Row("Xcode", "\(xcode)/MacOS/Xcode", nil, .editorApp),
        Row("Xcode", "/Applications/Xcode-beta.app/Contents/MacOS/Xcode", nil, .editorApp),
        Row("Xcode", "/Applications/Xcode_26.1.app/Contents/MacOS/Xcode", nil, .editorApp),
        Row("Xcode", "/Applications/Xcode-26.1.0.app/Contents/MacOS/Xcode", nil, .editorApp),
        Row("Xcode", "/Applications/Xcode 26.app/Contents/MacOS/Xcode", nil, .editorApp),
        Row("Electron", "\(code)/MacOS/Electron", nil, .editorApp),
        Row("Cursor", "/Applications/Cursor.app/Contents/MacOS/Cursor", nil, .editorApp),
        Row("zed", "/Applications/Zed.app/Contents/MacOS/zed", nil, .editorApp),
        Row("idea", "/Applications/IntelliJ IDEA CE.app/Contents/MacOS/idea", nil, .editorApp),
        Row("SourceKitService", "\(xcode)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService", "SourceKitService", .ideService),
        Row("fsnotifier", "/Applications/IntelliJ IDEA CE.app/Contents/bin/fsnotifier", nil, .ideService),
        // A service inside any Xcode is an IDE service, judged by where it lives rather than by its name.
        Row("DocumentationService", "\(xcode)/SharedFrameworks/DVTDocumentation.framework/Versions/A/XPCServices/DocumentationService.xpc/Contents/MacOS/DocumentationService", nil, .ideService),
        Row("DocumentationService", "/Applications/Xcode-beta.app/Contents/SharedFrameworks/DVTDocumentation.framework/Versions/A/XPCServices/DocumentationService.xpc/Contents/MacOS/DocumentationService", nil, .ideService),
        Row("DocumentationService", "/Applications/Xcode_26.1.app/Contents/SharedFrameworks/DVTDocumentation.framework/Versions/A/XPCServices/DocumentationService.xpc/Contents/MacOS/DocumentationService", nil, .ideService),
        Row("Code Helper (Plugin)", "\(code)/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
            "\(code)/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin) --type=utility", .electronApp),
        Row("Codex Helper", "/Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper",
            "/Applications/Codex.app/Contents/Frameworks/Electron Framework.framework/Helpers/helper", .electronApp),
        // Language servers.
        Row("rust-analyzer", "/Users/dev/.vscode/extensions/rust-lang.rust-analyzer-0.3.2/server/rust-analyzer", nil, .languageServer),
        Row("gopls", "/Users/dev/go/bin/gopls", "/Users/dev/go/bin/gopls -mode=stdio", .languageServer),
        Row("clangd", "/opt/homebrew/opt/llvm/bin/clangd", "clangd --background-index", .languageServer),
        Row("sourcekit-lsp", "\(toolchain)/sourcekit-lsp", nil, .languageServer),
        Row("node", "/usr/local/bin/node", "node /Users/dev/app/node_modules/typescript/lib/tsserver.js --serverMode partialSemantic", .languageServer),
        Row("node", "/usr/local/bin/node", "/usr/local/bin/node /Users/dev/.vscode/extensions/dbaeumer.vscode-eslint-3.0.10/server/out/eslintServer.js --node-ipc", .languageServer),
        Row("node", "/usr/local/bin/node", "node /Users/dev/.npm/bin/pyright-langserver --stdio", .languageServer),
        Row("lua-language-server", "/opt/homebrew/bin/lua-language-server", nil, .languageServer),
        Row("ruby-lsp", "/Users/dev/.gem/bin/ruby-lsp", nil, .languageServer),
        Row("zls", "/opt/homebrew/bin/zls", nil, .languageServer),
        // Databases.
        Row("postgres", "/opt/homebrew/opt/postgresql@16/bin/postgres", "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16", .dataStore),
        Row("postgres", "/opt/homebrew/opt/postgresql@16/bin/postgres", "postgres: checkpointer", .dataStore),
        Row("redis-server", "/opt/homebrew/opt/redis/bin/redis-server", "/opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379", .dataStore),
        Row("mysqld", "/opt/homebrew/opt/mysql/bin/mysqld", nil, .dataStore),
        Row("mongod", "/opt/homebrew/bin/mongod", "mongod --config /opt/homebrew/etc/mongod.conf", .dataStore),
        Row("beam.smp", "/opt/homebrew/Cellar/erlang/26/lib/erlang/erts/bin/beam.smp", "beam.smp -- -root /opt/homebrew/lib/erlang -s rabbit boot", .dataStore),
        Row("java", "/usr/bin/java", "java -Xms1g org.elasticsearch.bootstrap.Elasticsearch", .dataStore),
        // Containers and VMs.
        Row("com.docker.backend", "/Applications/Docker.app/Contents/MacOS/com.docker.backend", nil, .containerRuntime),
        Row("com.docker.virtualization", "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization", nil, .containerRuntime),
        Row("OrbStack Helper", "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper", nil, .containerRuntime),
        Row("limactl", "/opt/homebrew/bin/limactl", "limactl hostagent default", .containerRuntime),
        Row("qemu-system-aarch64", "/opt/homebrew/bin/qemu-system-aarch64", "qemu-system-aarch64 -m 4096", .containerRuntime),
        Row("docker", "/usr/local/bin/docker", "docker compose up", .containerRuntime),
        // Model runners.
        Row("ollama", "/usr/local/bin/ollama", "ollama serve", .localModelRunner),
        Row("llama-server", "/opt/homebrew/bin/llama-server", "llama-server -m model.gguf --port 8080", .localModelRunner),
        Row("LM Studio", "/Applications/LM Studio.app/Contents/MacOS/LM Studio", nil, .localModelRunner),
        Row("python3.12", "/opt/homebrew/bin/python3.12", "python3.12 -m mlx_lm.server --model mlx-community/Llama-3", .localModelRunner),
        // Simulators.
        Row("launchd_sim", "/Library/Developer/CoreSimulator/Volumes/iOS_22A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.0.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim", nil, .simulator),
        Row("Simulator", "\(xcode)/Developer/Applications/Simulator.app/Contents/MacOS/Simulator", nil, .simulator),
        // Builds, tests and watchers.
        Row("swift-frontend", "\(toolchain)/swift-frontend", "swift-frontend -frontend -c -primary-file main.swift", .swiftBuild),
        Row("xcodebuild", "/usr/bin/xcodebuild", "xcodebuild -scheme App build", .swiftBuild),
        Row("swift-build", "\(toolchain)/swift-build", "swift build -c release", .swiftBuild),
        Row("clang", "/usr/bin/clang", "clang -c foo.c", .cliTool),
        Row("node", "/usr/local/bin/node", "node /Users/dev/web/node_modules/.bin/jest --watch", .testRunner),
        Row("node", "/usr/local/bin/node", "node /Users/dev/web/node_modules/jest-worker/build/workers/processChild.js", .testRunner),
        Row("node", "/usr/local/bin/node", "node /Users/dev/web/node_modules/vitest/vitest.mjs run", .testRunner),
        Row("python3", "/opt/homebrew/bin/python3", "python3 -m pytest -x tests", .testRunner),
        Row("cargo", "/Users/dev/.cargo/bin/cargo", "cargo test --workspace", .testRunner),
        Row("go", "/opt/homebrew/bin/go", "go test ./...", .testRunner),
        Row("esbuild", "/Users/dev/web/node_modules/@esbuild/darwin-arm64/bin/esbuild", "esbuild --service=0.19.2 --ping", .buildWatcher),
        Row("node", "/usr/local/bin/node", "node /Users/dev/web/node_modules/.bin/tsc --watch", .buildWatcher),
        Row("watchexec", "/opt/homebrew/bin/watchexec", "watchexec -e rs cargo check", .buildWatcher),
        // Language runtimes and dev servers.
        Row("node", "/usr/local/bin/node", "node /Users/dev/web/node_modules/.bin/vite --port 5173", .nodeServer),
        Row("node", "/usr/local/bin/node", "node server.js", .nodeServer),
        Row("python3", "/opt/homebrew/bin/python3", "python3 -m uvicorn app.main:app --reload", .pythonService),
        Row("python3", "/opt/homebrew/bin/python3", "python3 -m ipykernel_launcher -f /Users/dev/Library/Jupyter/runtime/kernel-1.json", .pythonService),
        Row("air", "/opt/homebrew/bin/air", "air -c .air.toml", .goService),
        Row("my-rust-service", "/Users/dev/project/target/debug/my-rust-service", "./target/debug/my-rust-service", .rustService),
        Row("bun", "/opt/homebrew/bin/bun", "bun run server.ts", .bunServer),
        Row("deno", "/opt/homebrew/bin/deno", "deno run --allow-net server.ts", .denoServer),
        Row("dotnet", "/usr/local/share/dotnet/dotnet", "dotnet watch run", .dotnetService),
        // Negatives: substring look-alikes and ordinary system work.
        Row("Safari", "/Applications/Safari.app/Contents/MacOS/Safari", nil, .unknownHeavy, dev: false),
        Row("Xcodes", "/Applications/Xcodes.app/Contents/MacOS/Xcodes", nil, .unknownHeavy, dev: false),
        Row("Zedify", "/Applications/Zedify.app/Contents/MacOS/Zedify", nil, .unknownHeavy, dev: false),
        Row("Invites", "/Applications/Invites.app/Contents/MacOS/Invites", nil, .unknownHeavy, dev: false),
        Row("Foo Agent", "/Library/Application Support/Foo/Foo.bundle/Contents/MacOS/Foo Agent", nil, .unknownHeavy, dev: false),
        Row("WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", "WindowServer -daemon", .unknownHeavy, dev: false),
        Row("mdworker_shared", "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mdworker_shared",
            "mdworker_shared -s mdworker -c MDSImporterWorker -m com.apple.mdworker.shared", .unknownHeavy, dev: false),
        Row("QuickLookUIService", "/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService",
            "/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService /Users/dev/Documents/javascript/notes.txt", .unknownHeavy, dev: false),
        Row("AirPlayUIAgent", "/System/Library/CoreServices/AirPlayUIAgent", nil, .unknownHeavy, dev: false),
        Row("Mail", "/System/Applications/Mail.app/Contents/MacOS/Mail", nil, .unknownHeavy, dev: false),
    ]

    func testCatalogTable() {
        XCTAssertGreaterThanOrEqual(rows.count, 60)
        let classifier = DevProcessClassifier()
        for row in rows {
            let process = IntelligenceFixture.process(name: row.name, path: row.path, command: row.command)
            let classification = classifier.classification(for: process)
            XCTAssertEqual(classification.kind, row.kind, "\(row.name): \(row.command)", line: row.line)
            XCTAssertEqual(classification.confidence >= 0.35, row.dev,
                           "\(row.name) confidence \(classification.confidence)", line: row.line)
        }
    }

    /// The bundle names Xcode installs go by: beta, versioned and renamed
    /// copies sit beside the release. A name that goes on with a letter is
    /// another app, such as the Xcodes version manager.
    func testXcodeIsRecognisedByAnyBundleNameItGoesBy() {
        for name in ["xcode", "xcode-beta", "xcode_26.1", "xcode 26", "xcode-26.1.0", "xcode.beta", "xcode26"] {
            XCTAssertTrue(WorkloadCatalog.isXcodeBundle(name), name)
        }
        for name in ["xcodes", "xcodeproj-tools", "xcod", "xcoder", "zed", "code", ""] {
            XCTAssertFalse(WorkloadCatalog.isXcodeBundle(name), name)
        }
        XCTAssertTrue(WorkloadCatalog.isEditorBundle("xcode-beta"))
        XCTAssertFalse(WorkloadCatalog.isEditorBundle("zedify"), "short editor names match whole words only")
    }

    func testTraitsSayWhatTheWorkIsFor() {
        let classifier = DevProcessClassifier()
        func traits(_ name: String, _ command: String) -> WorkloadTraits {
            classifier.classification(for: IntelligenceFixture.process(name: name, path: "/usr/local/bin/\(name)", command: command)).traits
        }
        XCTAssertTrue(traits("node", "node /Users/dev/web/node_modules/.bin/vite --port 5173").contains(.devServer))
        XCTAssertTrue(traits("cargo", "cargo build --release").contains(.buildOrTest))
        XCTAssertTrue(traits("npm", "npm run build").contains(.buildOrTest))
        XCTAssertTrue(traits("python3", "python3 -m ipykernel_launcher -f kernel.json").contains(.notebookKernel))
        XCTAssertFalse(traits("node", "node server.js").contains(.buildOrTest))
    }

    func testOldDockerKindStillDecodes() throws {
        let decoded = try JSONDecoder().decode([DevProcessKind].self, from: Data(#"["dockerHelper"]"#.utf8))
        XCTAssertEqual(decoded, [.containerRuntime])
        XCTAssertEqual(DevProcessKind.dockerHelper, .containerRuntime)
    }

    func testSamplerHintsCoverTheCatalogsQuietTools() {
        for name in ["rust-analyzer", "gopls", "clangd", "sourcekit-lsp", "sourcekitservice", "postgres", "redis-server",
                     "esbuild", "jest", "vitest", "llama-server", "com.docker.backend", "orbstack helper", "launchd_sim"] {
            XCTAssertTrue(WorkloadCatalog.probeHintNames.contains(name), name)
        }
    }
}
