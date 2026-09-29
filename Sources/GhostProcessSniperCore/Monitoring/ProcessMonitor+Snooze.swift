import Foundation

extension ProcessMonitor {
    /// Snoozes a family by its family key or signature id. A live family
    /// names its own rule. Otherwise the family has exited since the caller
    /// drew it (or restarted under a new pid, so its old key matches nothing),
    /// or nothing has been sampled yet, as when a notification's Snooze
    /// relaunched the app. The rule is then saved for the signature inside
    /// the key, titled with `name`, so it holds for the restarted copy too.
    public func snooze(signatureID: String, name: String? = nil, minutes: TimeInterval = 60) async {
        if let family = family(signatureID: signatureID) {
            await snooze(family, minutes: minutes)
            return
        }
        guard let target = unsampledTarget(key: signatureID, name: name) else { return }
        await save(rule: RadarRule(
            name: "Snooze \(target.name)",
            isBuiltIn: false,
            match: RadarRuleMatch(signatureID: target.signatureID, minimumLevel: .quiet),
            action: .snooze,
            expiresAt: Date().addingTimeInterval(minutes * 60)
        ))
    }

    /// Ignores a family the way `snooze(signatureID:name:minutes:)` snoozes it.
    public func ignore(signatureID: String, name: String? = nil) async {
        if let family = family(signatureID: signatureID) {
            await ignore(family)
            return
        }
        guard let target = unsampledTarget(key: signatureID, name: name) else { return }
        await save(rule: RadarRule(
            name: "Ignore \(target.name)",
            isBuiltIn: false,
            match: RadarRuleMatch(signatureID: target.signatureID, minimumLevel: .quiet),
            action: .ignore
        ))
    }

    /// What a rule for a family that is not in the scan holds on to: its
    /// signature id, and a name for the rule. The caller's name wins; else the
    /// signature id starts with the lowercased display name. Nil for a key
    /// with no signature in it, which would only save a rule that never matches.
    private func unsampledTarget(key: String, name: String?) -> (signatureID: String, name: String)? {
        let signatureID = ProcessFamily.signatureID(fromFamilyKey: key)
        guard !signatureID.isEmpty else { return nil }
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fromSignature = String(signatureID.prefix { $0 != "|" })
        return (signatureID, given.isEmpty ? (fromSignature.isEmpty ? "process" : fromSignature) : given)
    }
}
