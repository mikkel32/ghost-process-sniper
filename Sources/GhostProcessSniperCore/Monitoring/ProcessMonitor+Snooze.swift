import Foundation

extension ProcessMonitor {
    /// Snoozes by signature even when no live family carries it, as when a
    /// notification's Snooze relaunched the app before its first sample.
    /// `name` titles the rule then; a live family names it itself.
    public func snooze(signatureID: String, name: String, minutes: TimeInterval = 60) async {
        if let family = family(signatureID: signatureID) {
            await snooze(family, minutes: minutes)
            return
        }
        await save(rule: RadarRule(
            name: "Snooze \(name)",
            isBuiltIn: false,
            match: RadarRuleMatch(signatureID: signatureID, minimumLevel: .quiet),
            action: .snooze,
            expiresAt: Date().addingTimeInterval(minutes * 60)
        ))
    }
}
