import Foundation

/// The facts Sentinel judges a process by. Built from a scan's
/// `ProcessMetrics` or from a spawn the watcher caught mid-flight.
struct SentinelSubject: Sendable {
    let identity: ProcessIdentity
    let parentPID: Int32
    let userID: UInt32
    let name: String
    let executablePath: String
    let commandLine: String
    let isSystemProcess: Bool
    /// TCP ports it listens on, when the sampler has read them.
    var listeningPorts: [Int] = []
    /// A shell puts each pipeline in a process group of its own.
    var processGroupID: Int32?

    init(_ process: ProcessMetrics) {
        identity = process.identity
        parentPID = process.parentPID
        userID = process.userID
        name = process.name
        executablePath = process.executablePath
        commandLine = process.commandLine
        isSystemProcess = process.isSystemProcess
        listeningPorts = process.forensics.listeningPorts
        processGroupID = process.processGroupID
    }

    init(identity: ProcessIdentity, parentPID: Int32, userID: UInt32, name: String, executablePath: String,
         commandLine: String, isSystemProcess: Bool, processGroupID: Int32? = nil) {
        self.processGroupID = processGroupID
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.isSystemProcess = isSystemProcess
    }

    var program: String { SentinelCatalog.programName(name, path: executablePath) }
    var isCommandRunner: Bool { SentinelCatalog.isCommandRunner(name, path: executablePath) }
    var isInAppBundle: Bool { executablePath.contains(".app/") }
    var isSystemLocation: Bool { SentinelCatalog.isSystemLocation(executablePath) }

    /// Command-line tools (including Apple's cp, sqlite3 or security) run
    /// what someone typed or injected; an app's helpers and Apple's daemons
    /// run their vendor's own arguments.
    var commandIsWorthReading: Bool {
        if isCommandRunner { return true }
        let lower = executablePath.lowercased()
        if ["/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/", "/usr/local/bin/", "/opt/homebrew/bin/"].contains(where: lower.hasPrefix) {
            return true
        }
        return !isInAppBundle && !isSystemLocation && !executablePath.isEmpty
    }
}

struct SentinelEvaluation: Sendable {
    var signals: [SentinelSignal]
    var headline: String
    var recommendation: String
    /// The nearest browser, mail, chat or document app above this process.
    var contentAncestor: (name: String, role: SentinelCatalog.ContentApp)?
    var fromTerminal: Bool

    var severity: SentinelSeverity { signals.map(\.severity).max() ?? .info }
}

enum SentinelRules {
    /// How far up the tree a content app still counts as the launcher:
    /// Chrome › sh › curl is two steps; three allows one wrapper more.
    static let lineageReach = 3

    /// `ancestors` runs from the process's parent upward (nearest first).
    /// `signing` is the executable's signature once the inspector has read
    /// it; until then the rules that depend on it give the quieter verdict.
    /// `pipeline` is the command a stdin runner is part of, put back together
    /// from its siblings (`curl … | sh`), when the correlator found one.
    static func evaluate(_ subject: SentinelSubject, ancestors: [SentinelSubject], signing: CodeSigningSummary? = nil,
                         pipeline: PipelineCorrelator.Pipeline? = nil,
                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> SentinelEvaluation {
        var signals: [SentinelSignal] = []

        // Who launched it.
        var contentAncestor: (name: String, role: SentinelCatalog.ContentApp)?
        var forExtension = isNativeMessagingHost(subject.commandLine)
        for ancestor in ancestors.prefix(lineageReach) {
            if let role = SentinelCatalog.contentApp(path: ancestor.executablePath, name: ancestor.name) {
                contentAncestor = (SentinelCatalog.appName(forPath: ancestor.executablePath) ?? ancestor.name, role)
                break
            }
            // A runner may sit between (Chrome › sh › curl); anything else ends the climb.
            guard ancestor.isCommandRunner else { break }
            forExtension = forExtension || isNativeMessagingHost(ancestor.commandLine)
        }
        let fromTerminal = ancestors.prefix(5).contains { SentinelCatalog.isTerminalApp(path: $0.executablePath, name: $0.name) }
        if subject.isCommandRunner, let content = contentAncestor {
            signals.append(appSpawnedShell(subject, by: content, forExtension: forExtension))
        }

        // What it runs.
        if subject.commandIsWorthReading {
            signals += CommandPatterns.signals(commandLine: subject.commandLine, program: subject.program)
        }
        if let pipeline {
            // The runner is where the download runs, so it carries the finding.
            let whole = CommandPatterns.signals(commandLine: pipeline.text, program: subject.program)
                .filter { [.downloadAndExecute, .encodedPayload].contains($0.kind) && !signals.map(\.kind).contains($0.kind) }
            signals += whole.map { signal in
                SentinelSignal(signal.kind, signal.severity,
                               signal.detail + " Put together from \(pipeline.processCount) processes started as one pipeline: \(pipeline.text)",
                               evidence: signal.evidence)
            }
        }

        // Where it lives.
        signals += locationSignals(subject, signing: signing, fileExists: fileExists)
        if let masquerade = masquerade(subject) ?? lookalikeName(subject) {
            signals.append(masquerade)
        }
        if let disguise = disguisedAsDocument(subject) {
            signals.append(disguise)
        }
        let context = ListenerContext(
            oddlyLocated: signals.contains { [.temporaryLocation, .hiddenLocation].contains($0.kind) && $0.severity >= .suspicious },
            signing: signing, interactive: startedFromInteractiveShell(ancestors),
            corroborated: signals.contains { corroboratingKinds.contains($0.kind) && $0.severity >= .notable })
        if let listener = listener(subject, context: context) {
            signals.append(listener)
        }

        signals = escalate(signals, contentAncestor: contentAncestor)
        let headline = headline(for: subject, signals: signals, contentAncestor: contentAncestor, fromTerminal: fromTerminal)
        return SentinelEvaluation(
            signals: signals,
            headline: headline,
            recommendation: recommendation(for: signals, fromTerminal: fromTerminal),
            contentAncestor: contentAncestor,
            fromTerminal: fromTerminal
        )
    }

    // MARK: - Location

    static func locationSignals(_ subject: SentinelSubject, signing: CodeSigningSummary? = nil,
                                fileExists: (String) -> Bool) -> [SentinelSignal] {
        let path = subject.executablePath
        guard path.hasPrefix("/"), !subject.isSystemLocation else { return [] }
        var found: [SentinelSignal] = []
        let lower = path.lowercased()
        if SentinelCatalog.temporaryPrefixes.contains(where: lower.hasPrefix) {
            found.append(SentinelSignal(.temporaryLocation, .suspicious,
                "Runs from \((path as NSString).deletingLastPathComponent), a temporary folder where installed software never lives.",
                evidence: path))
        } else if SentinelCatalog.isPerUserTemporary(path), !subject.isInAppBundle {
            found.append(SentinelSignal(.temporaryLocation, .notable,
                "Runs from a per-user temporary folder. Installers do this briefly; long-running programs should not.",
                evidence: path))
        }
        if lower.hasPrefix("/users/shared/") {
            // Some vendors install here (Epic puts Unreal Engine here), so
            // only a program no known developer signed is suspicious; until
            // the signature is read, the quieter verdict stands.
            let unvouched = signing.map { !$0.isVouched } ?? false
            found.append(SentinelSignal(.hiddenLocation, unvouched ? .suspicious : .notable,
                "Runs from /Users/Shared, a folder every account can write to.", evidence: path))
        } else if isHiddenUserPath(lower) {
            found.append(SentinelSignal(.hiddenLocation, .notable,
                "Runs from a hidden folder in your home that is not a known developer tool location.", evidence: path))
        }
        if lower.range(of: #"^/users/[^/]+/downloads/"#, options: .regularExpression) != nil, !subject.isInAppBundle {
            found.append(SentinelSignal(.downloadedExecutable, .notable,
                "A program running straight from Downloads.", evidence: path))
        }
        if lower.hasPrefix("/volumes/"), !lower.hasPrefix("/volumes/macintosh hd") {
            found.append(SentinelSignal(.downloadedExecutable, .notable,
                "Runs from a mounted disk image or drive instead of being installed. Installers do this; so do fake ones.",
                evidence: path))
        }
        if lower.contains("/.trash/") {
            found.append(SentinelSignal(.hiddenLocation, .suspicious, "Runs from the Trash.", evidence: path))
        }
        if !fileExists(path) {
            let severity: SentinelSeverity = found.isEmpty ? .notable : .suspicious
            found.append(SentinelSignal(.deletedExecutable, severity,
                "Its program file no longer exists. Updates do this; so does malware that deletes itself after starting.",
                evidence: path))
        }
        return found
    }

    /// A dot-folder under a home directory that is not a known tool cache.
    static func isHiddenUserPath(_ lowerPath: String) -> Bool {
        guard lowerPath.hasPrefix("/users/") else { return false }
        let components = lowerPath.split(separator: "/")
        // users / name / ... ; a hidden component anywhere below the home folder.
        guard components.count > 3, components.dropFirst(2).contains(where: { $0.hasPrefix(".") }) else { return false }
        return !SentinelCatalog.knownToolDirectories.contains(where: lowerPath.contains)
    }

    // MARK: - Masquerade

    static func masquerade(_ subject: SentinelSubject) -> SentinelSignal? {
        let name = subject.name.lowercased()
        guard let expected = SentinelCatalog.protectedNames[name] else { return nil }
        let path = subject.executablePath.lowercased()
        // A booted simulator runs its own cfprefsd, trustd and tccd.
        guard !SentinelCatalog.isDeveloperPlatformLocation(path) else { return nil }
        if expected == [""] {
            guard !path.isEmpty else { return nil }
        } else {
            guard !path.isEmpty, !expected.contains(where: path.hasPrefix) else { return nil }
        }
        return SentinelSignal(.masquerade, .dangerous,
            "Calls itself \(subject.name), but the real \(subject.name) never runs from \(subject.executablePath).",
            evidence: subject.executablePath)
    }

    /// Letters from other alphabets that look like Latin ones, as used to
    /// fake a system name ("Fіnder" with a Cyrillic і).
    static let confusables: [Character: Character] = [
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s",
        "ԁ": "d", "һ": "h", "ӏ": "l", "ԛ": "q", "ԝ": "w", "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M",
        "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "Ѕ": "S", "І": "I", "Ј": "J",
        "ο": "o", "α": "a", "ν": "v", "τ": "t", "ι": "i", "Ο": "O", "Α": "A", "Β": "B", "Ε": "E", "Κ": "K", "Τ": "T",
    ]

    static func lookalikeName(_ subject: SentinelSubject) -> SentinelSignal? {
        guard subject.name.unicodeScalars.contains(where: { !$0.isASCII }) else { return nil }
        let folded = String(subject.name.map { confusables[$0] ?? $0 })
        guard folded != subject.name, folded.unicodeScalars.allSatisfy(\.isASCII),
              SentinelCatalog.protectedNames[folded.lowercased()] != nil || SentinelCatalog.contentApps[folded.lowercased()] != nil
        else { return nil }
        return SentinelSignal(.masquerade, .dangerous,
            "Its name looks like \(folded) but uses letters from another alphabet, a trick to pass for it.",
            evidence: subject.name)
    }

    /// "Invoice.pdf.app": an app named to look like a document.
    static func disguisedAsDocument(_ subject: SentinelSubject) -> SentinelSignal? {
        guard let app = SentinelCatalog.appName(forPath: subject.executablePath)?.lowercased() else { return nil }
        let documentExtensions = [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".jpg", ".jpeg", ".png",
                                  ".txt", ".rtf", ".zip", ".mp4", ".mov", ".csv"]
        guard let ext = documentExtensions.first(where: { app.hasSuffix($0) }) else { return nil }
        return SentinelSignal(.masquerade, .suspicious,
            "An app named like a \(ext.dropFirst().uppercased()) file. Real documents open in an app; they are not apps.",
            evidence: SentinelCatalog.appName(forPath: subject.executablePath))
    }

    // MARK: - Combining evidence

    /// Signals that together describe an attack chain outrank each alone.
    static func escalate(_ signals: [SentinelSignal],
                         contentAncestor: (name: String, role: SentinelCatalog.ContentApp)?) -> [SentinelSignal] {
        let kinds = Dictionary(signals.map { ($0.kind, $0.severity) }, uniquingKeysWith: max)
        let payloadKinds: [SentinelSignalKind] = [.downloadAndExecute, .encodedPayload, .passwordPrompt, .credentialAccess,
                                                  .reverseShell, .persistence, .quarantineRemoval]
        let carriesPayload = payloadKinds.contains { (kinds[$0] ?? .info) >= .notable }
        var result = signals
        if contentAncestor != nil, carriesPayload {
            result = result.map { signal in
                guard signal.kind == .appSpawnedShell else { return signal }
                return SentinelSignal(signal.kind, .dangerous, signal.detail + " The command it runs also carries a payload.",
                                      evidence: signal.evidence)
            }
        }
        // Download-and-run plus hiding or credential theft is a stealer's chain.
        let chain = (kinds[.downloadAndExecute] ?? .info) >= .notable
            && ((kinds[.encodedPayload] ?? .info) >= .notable || (kinds[.passwordPrompt] ?? .info) >= .notable
                || (kinds[.quarantineRemoval] ?? .info) >= .notable)
        if chain {
            result = result.map { signal in
                signal.kind == .downloadAndExecute
                    ? SentinelSignal(signal.kind, .dangerous, signal.detail + " Combined with the other steps, this matches how password stealers install.",
                                     evidence: signal.evidence)
                    : signal
            }
        }
        // A temporary or hidden binary that also hides its command or phones out.
        // A tunnel command counts, and so does a listener already judged a
        // backdoor; a listener still worth only a look (Suspicious) does not.
        let located = (kinds[.temporaryLocation] ?? .info) >= .suspicious || (kinds[.hiddenLocation] ?? .info) >= .suspicious
        let tunnel = signals.contains { $0.kind == .tunnel && $0.severity != .suspicious }
        if located, carriesPayload || tunnel || kinds[.cryptoMiner] != nil {
            result = result.map { signal in
                (signal.kind == .temporaryLocation || signal.kind == .hiddenLocation)
                    ? SentinelSignal(signal.kind, .dangerous, signal.detail, evidence: signal.evidence)
                    : signal
            }
        }
        return result
    }

    // MARK: - Words

    static func headline(for subject: SentinelSubject, signals: [SentinelSignal],
                         contentAncestor: (name: String, role: SentinelCatalog.ContentApp)?, fromTerminal: Bool) -> String {
        let program = subject.program
        let kinds = Set(signals.filter { $0.severity >= .notable }.map(\.kind))
        if let content = contentAncestor, kinds.contains(.appSpawnedShell) {
            if kinds.contains(.downloadAndExecute) { return "\(content.name) started \(program), which downloads and runs code" }
            if kinds.contains(.passwordPrompt) { return "\(content.name) started a fake password prompt" }
            if kinds.contains(.credentialAccess) { return "\(content.name) started \(program), which reads saved passwords" }
            return "\(content.name) started \(program)"
        }
        if kinds.contains(.masquerade) { return "\(subject.name) is not the real \(subject.name)" }
        if kinds.contains(.reverseShell) { return "\(program) is giving another computer a shell" }
        if kinds.contains(.credentialAccess) { return "\(program) is reading saved passwords or cookies" }
        if kinds.contains(.passwordPrompt) { return "\(program) is asking for your password" }
        if kinds.contains(.downloadAndExecute) {
            return fromTerminal ? "A pasted command downloads and runs code" : "\(program) downloads and runs code"
        }
        if kinds.contains(.encodedPayload) { return "\(program) runs a hidden, encoded command" }
        if kinds.contains(.cryptoMiner) { return "\(program) looks like a crypto miner" }
        guard let strongest = signals.max(by: { $0.severity < $1.severity }) else { return subject.name }
        return "\(displayName(subject)): \(strongest.kind.title.lowercased())"
    }

    static func recommendation(for signals: [SentinelSignal], fromTerminal: Bool) -> String {
        let severity = signals.map(\.severity).max() ?? .info
        let pasted = fromTerminal && signals.contains { $0.kind == .downloadAndExecute && $0.severity >= .notable }
        switch severity {
        case .dangerous:
            return pasted
                ? "Stop it now. If a website told you to paste this into Terminal (a fake CAPTCHA or \"fix\"), it was an attack: stop it, then change your passwords from another device."
                : "Stop it now, then check what launched it. Change important passwords from another device if you did not start this yourself."
        case .suspicious:
            return pasted
                ? "If a website, email or message told you to paste this into Terminal, it is an attack: stop it now. Otherwise check where the command came from."
                : "Check where it came from. If you do not recognise it, stop it and reveal its file to remove it."
        case .notable:
            return pasted
                ? "Fine if you pasted it from a source you trust. Never paste commands a website or a stranger asks you to."
                : "Probably fine if you started it yourself. Look closer if you did not."
        case .info:
            return "Nothing to do."
        }
    }

    private static func displayName(_ subject: SentinelSubject) -> String {
        SentinelCatalog.appName(forPath: subject.executablePath) ?? subject.name
    }
}
