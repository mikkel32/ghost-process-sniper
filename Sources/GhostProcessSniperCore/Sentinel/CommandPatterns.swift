import Foundation

/// Reads a command line for the shapes attacks take on macOS: paste-and-run
/// one-liners, encoded payloads, password dialogs, keychain and cookie theft,
/// reverse shells, persistence and miners. Each detector explains itself in
/// a sentence and quotes what matched.
///
/// Legitimate tools share some of these shapes (Homebrew installs with
/// `bash -c "$(curl …)"`, developers open tunnels), so a match here is
/// evidence, weighed with where the command came from, not a verdict.
enum CommandPatterns {
    /// Enough for any one-liner; long argv (Electron flags, JSON) is cut here.
    static let inspectedLength = 8_192

    static func signals(commandLine: String, program: String) -> [SentinelSignal] {
        let command = String(commandLine.prefix(inspectedLength))
        let lower = command.lowercased()
        var found: [SentinelSignal] = []

        if let signal = downloadAndExecute(lower, original: command) { found.append(signal) }
        if let signal = encodedPayload(lower, original: command) { found.append(signal) }
        found += passwordPrompt(lower, original: command)
        found += credentialAccess(lower, original: command, program: program)
        if let signal = quarantineRemoval(lower, original: command) { found.append(signal) }
        found += persistence(lower, original: command)
        if let signal = reverseShell(lower, original: command) { found.append(signal) }
        if let signal = tunnel(lower, original: command, program: program) { found.append(signal) }
        if let signal = miner(lower, original: command, program: program) { found.append(signal) }
        found += capture(lower, original: command, program: program)
        return found
    }

    // MARK: - Download and execute

    /// Install scripts people run on purpose, by URL prefix.
    static let knownInstallers: [String] = [
        "https://raw.githubusercontent.com/homebrew/install/", "https://sh.rustup.rs", "https://bun.sh/install",
        "https://deno.land/install.sh", "https://deno.land/x/install", "https://ollama.com/install.sh",
        "https://get.pnpm.io/install.sh", "https://raw.githubusercontent.com/nvm-sh/nvm/", "https://install.python-poetry.org",
        "https://astral.sh/uv/", "https://astral.sh/ruff/", "https://get.docker.com", "https://tailscale.com/install.sh",
        "https://claude.ai/install.sh", "https://install.determinate.systems/nix", "https://nixos.org/nix/install",
        "https://get.sdkman.io", "https://starship.rs/install.sh", "https://fnm.vercel.app/install",
        "https://cli.moonrepo.dev/install", "https://mise.run", "https://pixi.sh/install.sh", "https://get.volta.sh",
        "https://sh.brew.sh", "https://cursor.com/install", "https://opencode.ai/install", "https://ohmyz.sh",
        "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/",
    ]

    static let pipeToRunner = regex(#"\b(curl|wget|fetch)\b[^|;&\n]{0,400}\|\s*(sudo\s+(-\S+\s+)*)?(env\s+)?(/bin/|/usr/bin/)?(ba|z|da|k|fi)?sh\b|\b(curl|wget)\b[^|;&\n]{0,400}\|\s*(sudo\s+)?(python[0-9.]*|perl|ruby|node|osascript|php)\b"#)
    static let substitutionRun = regex(#"\b(ba|z|da|k)?sh\s+-c\s+["']?\$\(\s*(curl|wget)\b|\beval\s+["']?\$\(\s*(curl|wget)\b|do shell script\s+["'\\]*\s*(curl|wget)\b"#)
    /// A saved download later made executable or run, even with other
    /// steps (like stripping the quarantine mark) in between.
    static let downloadThenRun = regex(#"\b(curl|wget)\b[^;&|\n]{0,300}(\s-o\s*|\s--output\s+|\s-O\b)[^\n]{0,600}?(;|&&)\s*(chmod\s+[+0-7]*x\b|\./|(ba|z)?sh\s|open\s|/tmp/|/private/tmp/)"#)
    static let url = regex(#"(https?://[^\s"'|;)`]+)"#)
    static let ipHost = regex(#"https?://(\d{1,3}\.){3}\d{1,3}"#)
    static let pasteHosts = ["pastebin.com", "paste.ee", "hastebin", "transfer.sh", "0x0.st", "termbin.com", "bit.ly",
                             "tinyurl.com", "is.gd", "t.co/", "cutt.ly", "rb.gy", "file.io", "temp.sh", "gofile.io",
                             "anonfiles", "discord.com/api/webhooks", "cdn.discordapp.com", "ngrok", "trycloudflare.com"]

    static func downloadAndExecute(_ lower: String, original: String) -> SentinelSignal? {
        guard let match = firstMatch(pipeToRunner, lower, original) ?? firstMatch(substitutionRun, lower, original)
                ?? firstMatch(downloadThenRun, lower, original) else { return nil }
        let link = firstMatch(url, lower, original)
        let lowerLink = link?.lowercased() ?? ""
        if !lowerLink.isEmpty, knownInstallers.contains(where: lowerLink.hasPrefix) {
            return SentinelSignal(.downloadAndExecute, .info,
                "Runs a well-known installer script straight from the internet.", evidence: link)
        }
        let risky = lowerLink.hasPrefix("http://") || firstMatch(ipHost, lower, original) != nil
            || pasteHosts.contains(where: lowerLink.contains)
        if risky {
            return SentinelSignal(.downloadAndExecute, .suspicious,
                "Downloads code from \(lowerLink.hasPrefix("http://") ? "an unencrypted link" : "an address attackers favour") and runs it immediately.",
                evidence: link ?? match)
        }
        return SentinelSignal(.downloadAndExecute, .notable,
            "Downloads code and runs it immediately, without saving it for review.", evidence: link ?? match)
    }

    // MARK: - Encoded payloads

    static let decodeToRunner = regex(#"\b(base64|b64)\s+(-d|-D|--decode)\b[^;&\n]{0,200}\|\s*(sudo\s+)?(ba|z|da)?sh\b|\b(base64|b64)\s+(-d|-D|--decode)\b[^;&\n]{0,200}\|\s*(python[0-9.]*|perl|ruby|osascript)\b|\beval\s+["']?\$\([^)]{0,300}base64\s+(-d|-D|--decode)|\b(openssl\s+(enc\s+-d|base64\s+-d)|xxd\s+-r\s+-p)\b[^;&\n]{0,200}\|\s*(ba|z)?sh\b"#)
    static let scriptDecoder = regex(#"\bexec\s*\(\s*(__import__\s*\(\s*['"](base64|zlib|marshal|codecs)|base64\.b64decode|zlib\.decompress|marshal\.loads|bytes\.fromhex|codecs\.decode)|\beval\s*\(\s*(atob|buffer\.from)\b|\bpack\s*\(\s*["']h\*|mime::base64|\beval\s*\(\s*base64_decode\s*\("#)
    static let longBlob = regex(#"[a-z0-9+/]{240,}={0,2}"#)

    static func encodedPayload(_ lower: String, original: String) -> SentinelSignal? {
        if let match = firstMatch(decodeToRunner, lower, original) ?? firstMatch(scriptDecoder, lower, original) {
            return SentinelSignal(.encodedPayload, .suspicious,
                "Decodes hidden text and runs it, so the real command never appears in plain sight.",
                evidence: String(match.prefix(160)))
        }
        if lower.contains("base64"), let blob = firstMatch(longBlob, lower, original) {
            return SentinelSignal(.encodedPayload, .notable,
                "Carries a long encoded blob in its arguments.", evidence: String(blob.prefix(64)) + "…")
        }
        return nil
    }

    // MARK: - Passwords and credentials

    static let dialogPassword = regex(#"display\s+dialog[^\n]{0,600}(hidden\s+answer|password)"#)
    static let authOnly = regex(#"\bdscl\s+(\.|/local/default|localhost)\s+-authonly\b"#)
    static let sudoStdin = regex(#"\becho\s+\S+[^|\n]{0,40}\|\s*sudo\s+(-\S*\s+)*-S\b"#)

    static func passwordPrompt(_ lower: String, original: String) -> [SentinelSignal] {
        var found: [SentinelSignal] = []
        if lower.contains("osascript") || lower.contains("display dialog"),
           let match = firstMatch(dialogPassword, lower, original) {
            found.append(SentinelSignal(.passwordPrompt, .suspicious,
                "Shows a homemade dialog asking for your password. Real macOS prompts never come from osascript.",
                evidence: String(match.prefix(160))))
        }
        if let match = firstMatch(authOnly, lower, original) {
            found.append(SentinelSignal(.passwordPrompt, .suspicious,
                "Checks whether a password is correct, which password stealers do before using it.", evidence: match))
        }
        if let match = firstMatch(sudoStdin, lower, original) {
            found.append(SentinelSignal(.passwordPrompt, .notable,
                "Feeds a password to sudo from the command line.", evidence: redacted(match)))
        }
        return found
    }

    static let safeStorage = regex(#"\bsecurity\s+find-generic-password\b[^\n]{0,200}(chrome|chromium|brave|edge|opera|vivaldi|arc|yandex|electron)\s+safe\s+storage"#)
    static let keychainRead = regex(#"\bsecurity\s+(find-generic-password|find-internet-password)\b[^\n]{0,200}\s-[a-z]*w"#)
    static let keychainDump = regex(#"\bsecurity\s+(dump-keychain|export)\b"#)
    static let secretStores = regex(#"(login data|web data|cookies\.binarycookies|/cookies\b|key4\.db|logins\.json|cookies\.sqlite|local state|login\.keychain|notestore\.sqlite|local extension settings/|wallets?/|exodus|electrum|/tdata\b|keychains/)"#)

    static func credentialAccess(_ lower: String, original: String, program: String) -> [SentinelSignal] {
        var found: [SentinelSignal] = []
        if let match = firstMatch(safeStorage, lower, original) {
            found.append(SentinelSignal(.credentialAccess, .dangerous,
                "Reads a browser's cookie-encryption key from the keychain, the first step of stealing logged-in sessions.",
                evidence: match))
        } else if let match = firstMatch(keychainRead, lower, original) {
            found.append(SentinelSignal(.credentialAccess, .notable,
                "Reads a saved password from the keychain.", evidence: match))
        }
        if let match = firstMatch(keychainDump, lower, original) {
            found.append(SentinelSignal(.credentialAccess, .suspicious,
                "Exports keychain contents.", evidence: match))
        }
        let copiers: Set<String> = ["sqlite3", "cp", "ditto", "zip", "tar", "cat", "python", "python3", "curl", "rsync", "scp"]
        if copiers.contains(program), let match = firstMatch(secretStores, lower, original) {
            found.append(SentinelSignal(.credentialAccess, .dangerous,
                "A command-line tool is reading or copying a password, cookie or wallet store.", evidence: match))
        }
        return found
    }

    // MARK: - Gatekeeper, persistence

    static let stripQuarantine = regex(#"\bxattr\s+(-[a-z]+\s+)*-[a-z]*d[a-z]*\s+(-[a-z]+\s+)*com\.apple\.quarantine\b|\bxattr\s+(-[a-z]+\s+)*-[a-z]*c[a-z]*\s+\S|\bspctl\s+(--master-disable|--global-disable|--disable)"#)

    static func quarantineRemoval(_ lower: String, original: String) -> SentinelSignal? {
        guard let match = firstMatch(stripQuarantine, lower, original) else { return nil }
        if match.contains("spctl") {
            return SentinelSignal(.quarantineRemoval, .suspicious, "Turns off Gatekeeper for the whole Mac.", evidence: match)
        }
        return SentinelSignal(.quarantineRemoval, .notable,
            "Removes the download mark, so macOS skips its first-launch safety check.", evidence: match)
    }

    static let launchctlLoad = regex(#"\blaunchctl\s+(load|bootstrap|submit|enable)\b[^\n;&|]{0,200}"#)
    static let agentWrite = regex(#"\b(cp|mv|tee|ditto|plutil|defaults\s+write|cat\s*>|echo[^\n]{0,200}>)\s*[^\n;&|]{0,200}library/launch(agents|daemons)/"#)
    static let loginHook = regex(#"defaults\s+write\s+com\.apple\.loginwindow\s+(loginhook|logouthook)|make\s+(new\s+)?login\s+item|\bcrontab\s+(-e\b|[^-\s])"#)

    static func persistence(_ lower: String, original: String) -> [SentinelSignal] {
        var found: [SentinelSignal] = []
        if let match = firstMatch(agentWrite, lower, original) {
            found.append(SentinelSignal(.persistence, .suspicious,
                "Writes a launch agent or daemon, so something starts with every login.", evidence: match))
        } else if let match = firstMatch(launchctlLoad, lower, original) {
            found.append(SentinelSignal(.persistence, .notable,
                "Registers a background job with launchd.", evidence: String(match.prefix(160))))
        }
        if let match = firstMatch(loginHook, lower, original) {
            found.append(SentinelSignal(.persistence, .notable,
                "Adds something that runs automatically at login or on a schedule.", evidence: match))
        }
        return found
    }

    // MARK: - Remote control, tunnels, miners, capture

    static let reverse = regex(#"/dev/(tcp|udp)/|\b(nc|ncat|netcat)\b[^\n]{0,120}\s-[a-z]*[ec]\s|\bsocat\b[^\n]{0,160}\bexec:|\b(ba|z)?sh\s+-i\s*[>&<]{1,3}|socket\b[^\n]{0,300}(subprocess|pty\.spawn|os\.dup2)|\bfsockopen\s*\(|\bruby\s+-rsocket\b|mkfifo\s+\S+[^\n]{0,120}\|\s*(nc|ncat|netcat)\b"#)

    static func reverseShell(_ lower: String, original: String) -> SentinelSignal? {
        guard let match = firstMatch(reverse, lower, original) else { return nil }
        return SentinelSignal(.reverseShell, .dangerous,
            "Connects a shell to another computer, giving it remote control of this Mac.", evidence: String(match.prefix(160)))
    }

    static let tunnels = regex(#"\bngrok\s+(http|tcp|tls|start)\b|\bcloudflared\s+tunnel\b|\bssh\b[^\n]{0,200}\s-[a-z]*r\s*\d|\bfrpc\b|\bchisel\s+client\b|\bbore\s+local\b|\blocaltunnel\b|\blt\s+--port\b"#)

    static func tunnel(_ lower: String, original: String, program: String) -> SentinelSignal? {
        guard let match = firstMatch(tunnels, lower, original) else { return nil }
        return SentinelSignal(.tunnel, .notable,
            "Opens a tunnel that lets the internet reach this Mac.", evidence: match)
    }

    static let minerNames: Set<String> = ["xmrig", "xmr-stak", "minerd", "cpuminer", "nbminer", "t-rex", "lolminer",
                                          "ethminer", "phoenixminer", "nanominer", "srbminer-multi", "cgminer", "bfgminer"]
    static let minerArgs = regex(#"stratum\+(tcp|ssl|tls)://|--donate-level\b|\s-o\s+[^\s]*pool\.|\bnicehash\b|\bmoneroocean\b|\bsupportxmr\b"#)

    static func miner(_ lower: String, original: String, program: String) -> SentinelSignal? {
        if minerNames.contains(program) {
            return SentinelSignal(.cryptoMiner, .suspicious, "Runs a known cryptocurrency miner.", evidence: program)
        }
        guard let match = firstMatch(minerArgs, lower, original) else { return nil }
        return SentinelSignal(.cryptoMiner, .suspicious, "Connects to a cryptocurrency mining pool.", evidence: match)
    }

    static let screenGrab = regex(#"\bscreencapture\b[^\n;&|]{0,120}\s-[a-z]*x"#)
    static let avCapture = regex(#"\bffmpeg\b[^\n]{0,300}-f\s+avfoundation\b"#)

    static func capture(_ lower: String, original: String, program: String) -> [SentinelSignal] {
        var found: [SentinelSignal] = []
        if let match = firstMatch(screenGrab, lower, original) {
            found.append(SentinelSignal(.screenCapture, .notable,
                "Takes silent screenshots (no shutter sound).", evidence: match))
        }
        if let match = firstMatch(avCapture, lower, original) {
            let screen = lower.contains("capture screen") || lower.range(of: #"-i\s+["']?[1-9]"#, options: .regularExpression) != nil
            found.append(SentinelSignal(screen ? .screenCapture : .cameraCapture, .notable,
                screen ? "Records the screen with ffmpeg." : "Records the camera or microphone with ffmpeg.",
                evidence: String(match.prefix(160))))
        }
        if program == "imagesnap" {
            found.append(SentinelSignal(.cameraCapture, .notable, "Takes a photo with the camera.", evidence: program))
        }
        return found
    }

    // MARK: - Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals checked by the tests; a typo must fail loudly.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Matches on the lowercased text and quotes the same span of the
    /// original, so evidence keeps its real capitalisation.
    static func firstMatch(_ expression: NSRegularExpression, _ lower: String, _ original: String) -> String? {
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        guard let match = expression.firstMatch(in: lower, range: range),
              let lowerSpan = Range(match.range, in: lower) else { return nil }
        // Lowercasing can change a string's length (rare Unicode); then the
        // offsets only fit the lowercased text.
        if original.utf16.count == lower.utf16.count, let originalSpan = Range(match.range, in: original) {
            return String(original[originalSpan]).trimmingCharacters(in: .whitespaces)
        }
        return String(lower[lowerSpan]).trimmingCharacters(in: .whitespaces)
    }

    /// Hides a secret passed on the command line before it reaches the UI.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: #"echo\s+\S+"#, with: "echo ••••••", options: .regularExpression)
    }
}
