import Foundation

/// What Sentinel knows about apps and places. Everything here is a plain
/// lookup, so a rule reads like the sentence it implements.
public enum SentinelCatalog {
    /// Apps whose job is showing content from strangers. None of them has a
    /// normal reason to start a shell, an interpreter or a download tool.
    public enum ContentApp: String, Sendable {
        case browser
        case mail
        case chat
        case document

        var label: String {
            switch self {
            case .browser: "web browser"
            case .mail: "mail app"
            case .chat: "chat app"
            case .document: "document app"
            }
        }
    }

    /// Bundle names (the `.app` folder without extension), lowercased.
    static let contentApps: [String: ContentApp] = [
        "google chrome": .browser, "google chrome beta": .browser, "google chrome canary": .browser,
        "chromium": .browser, "safari": .browser, "safari technology preview": .browser, "firefox": .browser,
        "firefox developer edition": .browser, "microsoft edge": .browser, "microsoft edge beta": .browser,
        "brave browser": .browser, "arc": .browser, "opera": .browser, "opera gx": .browser, "vivaldi": .browser,
        "orion": .browser, "zen browser": .browser, "zen": .browser, "dia": .browser, "sigmaos": .browser,
        "mail": .mail, "microsoft outlook": .mail, "spark": .mail, "spark desktop": .mail, "airmail 5": .mail,
        "thunderbird": .mail, "mimestream": .mail, "superhuman": .mail,
        "slack": .chat, "discord": .chat, "microsoft teams": .chat, "microsoft teams (work or school)": .chat,
        "telegram": .chat, "whatsapp": .chat, "signal": .chat, "messages": .chat, "zoom.us": .chat, "skype": .chat,
        "microsoft word": .document, "microsoft excel": .document, "microsoft powerpoint": .document,
        "pages": .document, "numbers": .document, "keynote": .document, "preview": .document,
        "adobe acrobat reader": .document, "adobe acrobat": .document, "libreoffice": .document,
    ]

    /// WebKit and Chromium do their work in XPC helpers named after the engine.
    static let contentHelperNames: [String: ContentApp] = [
        "com.apple.webkit.webcontent": .browser, "com.apple.webkit.networking": .browser,
    ]

    /// Terminals: whatever their shells run was typed or pasted by someone.
    static let terminalApps: Set<String> = [
        "terminal", "iterm", "iterm2", "warp", "ghostty", "wezterm", "wezterm-gui", "kitty", "alacritty",
        "hyper", "tabby", "rio", "wave",
    ]

    /// Programs that turn text into actions: the usual second step of an attack.
    static let commandRunners: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "tcsh", "csh", "ksh",
        "osascript", "python", "python2", "python3", "perl", "ruby", "php", "node", "bun", "deno", "tclsh",
        "curl", "wget", "nc", "ncat", "netcat", "socat", "openssl", "base64", "xattr", "launchctl",
        "security", "dscl", "sqlite3", "screencapture", "ffmpeg", "open", "chmod", "ditto", "hdiutil",
        "installer", "pkgutil", "sudo", "nohup", "powershell", "pwsh",
    ]

    /// System daemons and apps malware likes to be mistaken for, with where
    /// the real ones live.
    static let protectedNames: [String: [String]] = [
        "launchd": ["/sbin/"], "kernel_task": [""], "windowserver": ["/system/library/"],
        "loginwindow": ["/system/library/"], "finder": ["/system/library/coreservices/"],
        "dock": ["/system/library/coreservices/"], "systemuiserver": ["/system/library/coreservices/"],
        "mds": ["/system/library/"], "mds_stores": ["/system/library/"], "mdworker": ["/system/library/"],
        "mdworker_shared": ["/system/library/"], "trustd": ["/usr/libexec/"], "syspolicyd": ["/usr/libexec/"],
        "cfprefsd": ["/usr/sbin/"], "securityd": ["/usr/sbin/"], "softwareupdated": ["/system/library/"],
        "xprotect": ["/library/apple/", "/system/library/", "/usr/bin/"],
        "xprotectservice": ["/library/apple/", "/system/library/"],
        "coreaudiod": ["/usr/sbin/"], "bluetoothd": ["/usr/sbin/"], "airportd": ["/usr/libexec/"],
        "sharingd": ["/usr/libexec/"], "nsurlsessiond": ["/usr/libexec/"], "apsd": ["/system/library/"],
        "syslogd": ["/usr/sbin/"], "configd": ["/usr/libexec/"], "notifyd": ["/usr/sbin/"],
        "distnoted": ["/usr/sbin/"], "tccd": ["/system/library/"], "sshd": ["/usr/sbin/", "/usr/libexec/"],
        "google chrome": ["/applications/", "/users/"], "safari": ["/applications/", "/system/", "/system/volumes/preboot/cryptexes/"],
    ]

    /// Hidden folders developers keep tools in. A binary here is normal.
    static let knownToolDirectories: [String] = [
        "/.cargo/", "/.rustup/", "/.nvm/", "/.bun/", "/.deno/", "/.volta/", "/.pyenv/", "/.rbenv/", "/.asdf/",
        "/.local/", "/.npm/", "/.pnpm", "/.yarn/", "/.vscode/", "/.vscode-server/", "/.cursor/", "/.windsurf/",
        "/.docker/", "/.orbstack/", "/.colima/", "/.lima/", "/.gradle/", "/.m2/", "/.sdkman/", "/.jenv/",
        "/.dotnet/", "/.nix-profile/", "/.nix-defexpr/", "/.cache/", "/.codex/", "/.claude/", "/.ollama/",
        "/.oh-my-zsh/", "/.tmux/", "/.zinit/", "/.fzf/", "/.gem/", "/.swiftpm/", "/.mint/", "/.proto/",
        "/.moon/", "/.go/", "/go/bin/", "/.kube/", "/.terraform", "/.pulumi/", "/.config/", "/.git/",
        "/.build/", "/.venv/", "/venv/", "/.tox/", "/.conda/", "/miniconda3/", "/anaconda3/", "/.pixi/",
    ]

    /// Temporary locations nothing should normally be *installed* in.
    static let temporaryPrefixes: [String] = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/"]

    /// Per-user temporary folders. Installers and Xcode legitimately run
    /// helpers from here, so this weighs less than /tmp.
    static func isPerUserTemporary(_ path: String) -> Bool {
        (path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/"))
            && (path.contains("/T/") || path.contains("/C/"))
            && !path.contains("/AppTranslocation/")
            && !path.contains("/com.apple.")
            && !path.contains("/Xcode/")
    }

    /// The `.app` a path belongs to ("Google Chrome"), outermost bundle.
    public static func appName(forPath path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : nil
        }
        let bundlePath = path[..<range.lowerBound]
        guard let slash = bundlePath.lastIndex(of: "/") else { return nil }
        return String(bundlePath[bundlePath.index(after: slash)...])
    }

    /// The content-app role of a process, from its bundle or helper name.
    static func contentApp(path: String, name: String) -> ContentApp? {
        if let helper = contentHelperNames[name.lowercased()] { return helper }
        guard let app = appName(forPath: path)?.lowercased() else { return nil }
        return contentApps[app]
    }

    static func isTerminalApp(path: String, name: String) -> Bool {
        if let app = appName(forPath: path)?.lowercased(), terminalApps.contains(app) { return true }
        return terminalApps.contains(name.lowercased())
    }

    /// The bare program name: "-zsh" → "zsh", "python3.12" → "python3".
    static func programName(_ name: String, path: String) -> String {
        // Plain string slicing: URL(fileURLWithPath:) would stat the file.
        let last = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
        var base = (path.isEmpty ? name : last ?? name).lowercased()
        if base.hasPrefix("-") { base.removeFirst() }
        if base.hasPrefix("python3.") { return "python3" }
        if base.hasPrefix("python2.") { return "python2" }
        return base
    }

    static func isCommandRunner(_ name: String, path: String) -> Bool {
        let program = programName(name, path: path)
        guard commandRunners.contains(program) else { return false }
        // A runner inside an app bundle is the app's own copy (Electron's
        // node, a bundled python), part of the app rather than a new program.
        return !path.contains(".app/Contents/")
    }

    static func isSystemLocation(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["/system/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/", "/library/apple/",
                "/system/volumes/preboot/cryptexes/"].contains(where: lower.hasPrefix)
            || isDeveloperPlatformLocation(lower)
    }

    /// Simulator runtimes and Xcode's platform folders ship their own copies
    /// of Apple daemons (`cfprefsd`, `trustd`, `tccd` …): a booted simulator
    /// runs them from its RuntimeRoot. A copy of such a tree in a temporary,
    /// shared or trashed folder is not Apple's and does not count.
    static func isDeveloperPlatformLocation(_ lowerPath: String) -> Bool {
        guard !temporaryPrefixes.contains(where: lowerPath.hasPrefix), !lowerPath.hasPrefix("/users/shared/"),
              !lowerPath.contains("/.trash/") else { return false }
        if lowerPath.hasPrefix("/library/developer/coresimulator/") { return true }
        if lowerPath.contains(".simruntime/"), lowerPath.contains("/runtimeroot/") { return true }
        // Xcode.app, Xcode-beta.app, Xcode_26.1.app …
        guard let platforms = lowerPath.range(of: ".app/contents/developer/platforms/") else { return false }
        return lowerPath[..<platforms.lowerBound].split(separator: "/").last?.hasPrefix("xcode") == true
    }
}
