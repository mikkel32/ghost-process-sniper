import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class FamilyBoundaryTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture
    private static let code = "/Applications/Visual Studio Code.app/Contents"

    private func editorTree(extra: [ProcessMetrics] = []) -> [ProcessMetrics] {
        let editor = Fixture.process(pid: 500, name: "Electron", path: "\(Self.code)/MacOS/Electron", command: "\(Self.code)/MacOS/Electron", megabytes: 400)
        let renderer = Fixture.process(pid: 501, parent: 500, name: "Code Helper (Renderer)",
                                       path: "\(Self.code)/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)",
                                       command: "Code Helper (Renderer) --type=renderer", megabytes: 300)
        let plugin = Fixture.process(pid: 502, parent: 500, name: "Code Helper (Plugin)",
                                     path: "\(Self.code)/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                                     command: "Code Helper (Plugin) --type=utility", megabytes: 250)
        return [editor, renderer, plugin] + extra
    }

    func testLanguageServerUnderAnEditorIsItsOwnFamily() throws {
        let analyzer = Fixture.process(pid: 503, parent: 502, name: "rust-analyzer",
                                       path: "/Users/dev/.vscode/extensions/rust-lang.rust-analyzer-0.3.2/server/rust-analyzer",
                                       command: "/Users/dev/.vscode/extensions/rust-lang.rust-analyzer-0.3.2/server/rust-analyzer",
                                       megabytes: 4_096, cpu: 12)
        var window = TrendWindow()
        let families = Fixture.scored(editorTree(extra: [analyzer]), window: &window)
        XCTAssertEqual(families.count, 2)
        let editor = try XCTUnwrap(families.first { $0.root.pid == 500 })
        let server = try XCTUnwrap(families.first { $0.root.pid == 503 })
        XCTAssertEqual(editor.members.map(\.pid).sorted(), [500, 501, 502])
        XCTAssertEqual(server.members.map(\.pid), [503])
        XCTAssertEqual(server.classification?.kind, .languageServer)
        XCTAssertEqual(server.parentFamilyKey, editor.familyKey)
        XCTAssertNil(editor.parentFamilyKey)
        XCTAssertEqual(editor.classification?.kind, .editorApp)
        XCTAssertEqual(editor.childFamilies(in: families).map(\.root.pid), [503])
    }

    func testNotebookKernelAndTypeScriptServerLeaveTheEditor() {
        let tsserver = Fixture.process(pid: 504, parent: 502, name: "node", path: "/usr/local/bin/node",
                                       command: "node /Users/dev/app/node_modules/typescript/lib/tsserver.js", megabytes: 600)
        let kernel = Fixture.process(pid: 505, parent: 502, name: "python3", path: "/opt/homebrew/bin/python3",
                                     command: "python3 -m ipykernel_launcher -f /Users/dev/Library/Jupyter/runtime/kernel-1.json", megabytes: 900)
        var window = TrendWindow()
        let families = Fixture.scored(editorTree(extra: [tsserver, kernel]), window: &window)
        XCTAssertEqual(Set(families.map(\.root.pid)), [500, 504, 505])
        XCTAssertEqual(families.first { $0.root.pid == 504 }?.classification?.kind, .languageServer)
        XCTAssertEqual(families.first { $0.root.pid == 505 }?.classification?.traits.contains(.notebookKernel), true)
    }

    func testPlainHelperTreesStayGrouped() {
        var window = TrendWindow()
        let families = Fixture.scored(editorTree(), window: &window)
        XCTAssertEqual(families.count, 1)
        XCTAssertEqual(families.first?.members.count, 3)
    }

    /// The catalog calls everything inside LM Studio.app a model runner; its
    /// own renderer and GPU helpers are still the app, not servers it launched.
    func testAppBundleHelpersOfAServiceKindAppStayGrouped() throws {
        let bundle = "/Applications/LM Studio.app/Contents"
        func helper(_ pid: Int32, _ role: String) -> ProcessMetrics {
            let name = "LM Studio Helper (\(role))"
            return Fixture.process(pid: pid, parent: 800, name: name, path: "\(bundle)/Frameworks/\(name).app/Contents/MacOS/\(name)",
                                   command: "\(name) --type=\(role.lowercased())", megabytes: 200)
        }
        let main = Fixture.process(pid: 800, name: "LM Studio", path: "\(bundle)/MacOS/LM Studio",
                                   command: "\(bundle)/MacOS/LM Studio", megabytes: 500)
        var window = TrendWindow()
        let families = Fixture.scored([main, helper(801, "Renderer"), helper(802, "GPU")], window: &window)
        XCTAssertEqual(families.count, 1)
        let family = try XCTUnwrap(families.first)
        XCTAssertEqual(family.members.map(\.pid).sorted(), [800, 801, 802])
        XCTAssertEqual(family.classification?.kind, .localModelRunner)
        XCTAssertNil(family.parentFamilyKey)
    }

    /// A server shipped inside the app's own bundle is still a server: the
    /// same-bundle exception covers only helpers of the app's own kind.
    func testBundledServerOfAnEditorStillLeavesIt() {
        let xcode = "/Applications/Xcode.app/Contents"
        let editor = Fixture.process(pid: 520, name: "Xcode", path: "\(xcode)/MacOS/Xcode", command: "\(xcode)/MacOS/Xcode", megabytes: 900)
        let lsp = "\(xcode)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        let server = Fixture.process(pid: 521, parent: 520, name: "sourcekit-lsp", path: lsp, command: lsp, megabytes: 700)
        var window = TrendWindow()
        let families = Fixture.scored([editor, server], window: &window)
        XCTAssertEqual(Set(families.map(\.root.pid)), [520, 521])
        XCTAssertEqual(families.first { $0.root.pid == 521 }?.classification?.kind, .languageServer)
    }

    func testDevServerWorkersStayWithTheirServer() {
        let vite = Fixture.process(pid: 600, parent: 1, name: "node", path: "/usr/local/bin/node",
                                   command: "node /Users/dev/web/node_modules/.bin/vite --port 5173", megabytes: 300)
        let esbuild = Fixture.process(pid: 601, parent: 600, name: "esbuild",
                                      path: "/Users/dev/web/node_modules/@esbuild/darwin-arm64/bin/esbuild",
                                      command: "esbuild --service=0.19.2 --ping", megabytes: 40)
        var window = TrendWindow()
        let families = Fixture.scored([vite, esbuild], window: &window)
        XCTAssertEqual(families.count, 1)
        XCTAssertEqual(families.first?.members.map(\.pid).sorted(), [600, 601])
        XCTAssertEqual(families.first?.classification?.kind, .nodeServer)
    }

    /// The label follows the root unless one member dominates this tick.
    func testDominantMemberNamesTheFamilyWithoutChangingMembership() {
        let launcher = Fixture.process(pid: 700, parent: 1, name: "node", path: "/usr/local/bin/node",
                                       command: "node /Users/dev/tools/runner.js", megabytes: 50, cpu: 1)
        let runner = Fixture.process(pid: 701, parent: 700, name: "ollama", path: "/usr/local/bin/ollama",
                                     command: "ollama runner --model llama3", megabytes: 5_000, cpu: 180)
        var window = TrendWindow()
        let families = Fixture.scored([launcher, runner], window: &window)
        XCTAssertEqual(families.count, 1)
        XCTAssertEqual(families.first?.classification?.kind, .localModelRunner)
        XCTAssertEqual(families.first?.members.count, 2)
    }
}
