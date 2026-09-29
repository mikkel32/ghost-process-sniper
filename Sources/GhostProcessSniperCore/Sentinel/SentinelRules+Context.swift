import Foundation

/// Rules that weigh who started a process and how it was signed, not only
/// what it runs: the same shape means different things from a browser, an
/// extension's helper or someone's own terminal.
extension SentinelRules {
    // MARK: - Launched by a content app

    /// A browser, mail, chat or document app starting a command runner. A
    /// browser extension's native-messaging host names the extension in its
    /// arguments; password managers and other extensions talk to the Mac
    /// this way, so on its own it is only worth a look.
    static func appSpawnedShell(_ subject: SentinelSubject, by content: (name: String, role: SentinelCatalog.ContentApp),
                                forExtension: Bool) -> SentinelSignal {
        let evidence = "\(content.name) › \(subject.program)"
        if forExtension {
            return SentinelSignal(.appSpawnedShell, .notable,
                "\(content.name) started \(subject.program) for a browser extension (a native-messaging host). Password managers and other extensions do this; check that you installed the extension.",
                evidence: evidence)
        }
        let severity: SentinelSeverity = content.role == .chat ? .notable : .suspicious
        return SentinelSignal(.appSpawnedShell, severity,
            "\(content.name) is a \(content.role.label). It started \(subject.program), which runs commands; \(content.role == .browser ? "browsers" : "apps like this") have no normal reason to.",
            evidence: evidence)
    }

    /// Chrome passes the extension's origin; Firefox passes the host
    /// manifest's path and the add-on's ID.
    static func isNativeMessagingHost(_ commandLine: String) -> Bool {
        commandLine.range(of: #"\b(chrome|moz)-extension://|/nativemessaginghosts/[^/]+\.json\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Listening

    /// Someone typed it: a shell sits between it and a terminal app, tmux or screen.
    static func startedFromInteractiveShell(_ ancestors: [SentinelSubject]) -> Bool {
        let chain = ancestors.prefix(8)
        guard let host = chain.firstIndex(where: {
            SentinelCatalog.isTerminalApp(path: $0.executablePath, name: $0.name) || ["tmux", "screen"].contains($0.program)
        }) else { return false }
        return chain[..<host].contains { ShellRole.isShell($0.program) }
    }

    /// Runs from a hidden home folder that no known tool uses, and its signature
    /// has been read and shows nobody vouches for it. Until then the quieter
    /// verdict stands, as it does for /Users/Shared, so a signed tool never
    /// flashes an alarm while it waits.
    static func isUnvouchedHiddenHome(_ subject: SentinelSubject, signing: CodeSigningSummary?) -> Bool {
        guard let signing, !signing.isVouched else { return false }
        return isHiddenUserPath(subject.executablePath.lowercased())
    }

    /// A coding assistant's own shell started it: a shell sits between it and
    /// Claude or Codex, which build programs and run them on someone's behalf.
    /// Unlike a terminal this is not "someone typed it", so it never counts for
    /// the listener rule. The assistant must run from where such tools install:
    /// a process that merely carries the name from /tmp or a hidden folder is
    /// not one.
    static func startedByCodingAgent(_ ancestors: [SentinelSubject]) -> Bool {
        let chain = ancestors.prefix(8)
        guard let host = chain.firstIndex(where: isTrustworthyCodingAgent) else { return false }
        return chain[..<host].contains { ShellRole.isShell($0.program) }
    }

    private static func isTrustworthyCodingAgent(_ process: SentinelSubject) -> Bool {
        guard process.executablePath.hasPrefix("/"),
              SentinelCatalog.isCodingAgent(path: process.executablePath, name: process.name) else { return false }
        // The same places the location rules distrust, and Downloads even for an app.
        let oddly = locationSignals(process, fileExists: { _ in true }).contains { $0.severity >= .notable }
        return !oddly && process.executablePath.lowercased().range(of: #"^/users/[^/]+/downloads/"#, options: .regularExpression) == nil
    }

    /// Signs of an attack other than where a program lives.
    static let corroboratingKinds: Set<SentinelSignalKind> = [
        .downloadAndExecute, .encodedPayload, .passwordPrompt, .credentialAccess, .reverseShell, .persistence,
        .quarantineRemoval, .cryptoMiner, .masquerade, .appSpawnedShell,
    ]

    struct ListenerContext {
        /// Runs from a temporary or hidden folder (Suspicious or above), or a
        /// hidden home folder nobody vouches for and nobody typed into.
        var oddlyLocated: Bool
        /// Nil until the inspector has read the signature.
        var signing: CodeSigningSummary?
        /// Started from a shell someone types into.
        var interactive: Bool
        /// Carries another sign of an attack besides where it lives.
        var corroborated: Bool
    }

    /// A shell or relay waiting for connections is how a backdoor looks. A
    /// program in an odd folder that listens is a backdoor only when nobody
    /// vouches for it, nobody typed it, and something else about it is wrong;
    /// a dev server built into /tmp is worth a look, not an alarm.
    static func listener(_ subject: SentinelSubject, context: ListenerContext) -> SentinelSignal? {
        guard !subject.listeningPorts.isEmpty else { return nil }
        let ports = subject.listeningPorts.prefix(4).map(String.init).joined(separator: ", ")
        let relays: Set<String> = ["nc", "ncat", "netcat", "socat"]
        if ShellRole.isShell(subject.program) || relays.contains(subject.program) {
            return SentinelSignal(.reverseShell, relays.contains(subject.program) ? .suspicious : .dangerous,
                "\(subject.program) is waiting for network connections on port \(ports).", evidence: ports)
        }
        // Signed by Apple, the App Store or a Developer ID: a server, wherever it lives.
        guard context.oddlyLocated, context.signing?.isVouched != true else { return nil }
        let backdoor = context.signing != nil && !context.interactive && context.corroborated
        return SentinelSignal(.tunnel, backdoor ? .dangerous : .suspicious,
            "A program in an unusual folder is accepting network connections on port \(ports).", evidence: ports)
    }
}
