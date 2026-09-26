import GhostProcessSniperCore

/// One verb for the same stop everywhere: an app is asked to quit like ⌘Q,
/// a lone process or a whole tree is stopped.
enum StopActionLabel {
    static func title(risk: KillRiskAssessment?, memberCount: Int, appName: String? = nil) -> String {
        guard let risk else { return "Stop\u{2026}" }
        if risk.appQuitPID != nil {
            return "Quit \(appName ?? "App")\u{2026}"
        }
        return memberCount == 1 ? "Stop Process\u{2026}" : "Stop Tree\u{2026}"
    }
}
