import Foundation
import XCTest
@testable import GhostProcessSniperCore

final class ShellRoleTests: XCTestCase {
    private typealias Fixture = IntelligenceFixture

    private func shell(_ name: String, _ command: String) -> ProcessMetrics {
        Fixture.process(pid: 700, parent: 600, name: name, path: "/bin/\(name.hasPrefix("-") ? String(name.dropFirst()) : name)",
                        command: command)
    }

    func testCommandShellsAndPromptsAreToldApart() {
        let commands = ["/bin/sh -c c++ -c a.cpp", "sh -ec make -C sub", "bash --norc -c ./configure", "bash ./scripts/build.sh",
                        "/bin/zsh -lc npm run build"]
        for command in commands {
            XCTAssertTrue(ShellRole.runsCommand(shell(String(command.split(separator: " ")[0].split(separator: "/").last!), command)), command)
        }
        let prompts: [(String, String)] = [("-zsh", "-zsh"), ("zsh", "zsh"), ("zsh", "/bin/zsh -l"), ("bash", "bash -i -c ls"),
                                           ("bash", "bash --login"), ("fish", "fish")]
        for (name, command) in prompts {
            XCTAssertFalse(ShellRole.runsCommand(shell(name, command)), command)
        }
    }

    /// `bash ./build.sh` at a prompt is a script; a login shell, `-c`, `-i` and a
    /// bare shell are not, and options that take a word must not hand it over.
    func testAScriptOperandIsTheFirstWordThatIsNotAnOption() {
        let scripts: [(String, String)] = [
            ("bash ./a.sh", "./a.sh"), ("/bin/bash -e ./scripts/build.sh --release", "./scripts/build.sh"),
            ("bash -o pipefail ./a.sh", "./a.sh"), ("bash -eo pipefail ./a.sh", "./a.sh"),
            ("bash -O extglob ./a.sh", "./a.sh"), ("zsh +o nomatch ./a.zsh", "./a.zsh"),
            ("sh -- ./a.sh", "./a.sh"), ("sh -x build.sh -c 1", "build.sh")
        ]
        for (command, operand) in scripts {
            let name = String(command.split(separator: " ")[0].split(separator: "/").last!)
            XCTAssertEqual(ShellRole.scriptOperand(shell(name, command)), operand, command)
        }
        let notScripts: [(String, String)] = [
            ("-zsh", "-zsh"), ("zsh", "zsh"), ("zsh", "/bin/zsh -l"), ("bash", "bash --login"), ("bash", "bash -i"),
            ("bash", "bash -i -c ls"), ("bash", "bash -c make"), ("zsh", "zsh -lc npm run build"), ("sh", "sh -ec make -C sub"),
            ("bash", "bash --rcfile /tmp/rc"), ("bash", "bash --init-file /tmp/rc -i"), ("bash", "bash -o pipefail"),
            ("tmux", "tmux new -s work"), ("python3", "python3 build.py")
        ]
        for (name, command) in notScripts {
            XCTAssertNil(ShellRole.scriptOperand(shell(name, command)), command)
        }
    }

    func testOnlyAToolsShellIsARecipeShell() {
        let recipe = shell("sh", "/bin/sh -c cc -c a.c")
        let make = Fixture.process(pid: 600, name: "make", path: "/usr/bin/make", command: "make -j8")
        let ninja = Fixture.process(pid: 600, name: "ninja", path: "/opt/homebrew/bin/ninja", command: "ninja -C build")
        XCTAssertTrue(ShellRole.isRecipeShell(recipe, launcher: make))
        XCTAssertTrue(ShellRole.isRecipeShell(recipe, launcher: ninja))
        let hosts = [
            Fixture.process(pid: 600, name: "tmux", path: "/opt/homebrew/bin/tmux", command: "tmux"),
            Fixture.process(pid: 600, name: "sshd-session", path: "/usr/libexec/sshd-session", command: "sshd-session"),
            Fixture.process(pid: 600, name: "-zsh", path: "/bin/zsh", command: "-zsh"),
            Fixture.process(pid: 600, name: "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
                            command: "Code Helper"),
        ]
        for host in hosts {
            XCTAssertFalse(ShellRole.isRecipeShell(recipe, launcher: host), host.name)
        }
        XCTAssertFalse(ShellRole.isRecipeShell(recipe, launcher: nil))
        XCTAssertFalse(ShellRole.isRecipeShell(shell("-zsh", "-zsh"), launcher: make))
    }
}
