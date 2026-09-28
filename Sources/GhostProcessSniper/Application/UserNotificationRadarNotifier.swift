import Foundation
import GhostProcessSniperCore
import UserNotifications

actor UserNotificationRadarNotifier: RadarNotifying {
    private var lastDelivered: [String: Date] = [:]
    private let minimumInterval: TimeInterval = 15 * 60
    // Each settings read is an XPC round trip to usernoted inside the awaited
    // refresh, so the status is cached and only re-read once a minute.
    private let statusCacheInterval: TimeInterval = 60
    private var cachedStatus: UNAuthorizationStatus?
    private var statusCheckedAt: Date = .distantPast
    private var didPromptThisLaunch = false
    // UNUserNotificationCenter raises NSInternalInconsistencyException in unbundled
    // dev builds (swift run / .build/debug binary), which have no bundle identifier.
    private let notificationCenterAvailable = Bundle.main.bundleIdentifier != nil

    func process(model: RadarModel) async {
        let candidates = model.families.filter { family in
            family.score.heat.shouldNotify &&
                family.alertState.kind != .ignored &&
                family.alertState.kind != .snoozed &&
                family.suggestions.contains { $0.type == .notify || $0.type == .suggestKill || $0.type == .inspect || $0.type == .kill }
        }

        for family in candidates.prefix(3) {
            await notifyIfNeeded(family: family, at: model.generatedAt)
        }
    }

    /// One alert per Sentinel finding; clicking it opens the Security page.
    func notify(sentinel finding: SentinelFinding) async {
        guard notificationCenterAvailable else { return }
        switch await currentStatus() {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            if !didPromptThisLaunch {
                didPromptThisLaunch = true
                Task { _ = await self.requestAuthorization() }
            }
            return
        default:
            return
        }
        let content = UNMutableNotificationContent()
        // Only a dangerous finding alerts after its process exited (a one-shot command caught in the act).
        content.title = !finding.isRunning ? "Security: a dangerous command ran"
            : finding.severity == .dangerous ? "Security: act now" : "Security: worth a look"
        content.subtitle = finding.headline
        var lines = [finding.lineageText] + finding.signals.prefix(2).map(\.detail)
        if !finding.isRunning { lines.append("It had already exited when Ghost reported it.") }
        content.body = lines.joined(separator: "\n")
        content.sound = finding.severity == .dangerous ? .defaultCritical : .default
        content.categoryIdentifier = NotificationRouter.sentinelCategory
        content.userInfo = ["sentinelFinding": finding.id]
        content.threadIdentifier = "ghost.sentinel"
        let request = UNNotificationRequest(identifier: "ghost.sentinel.\(finding.id)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            RadarLogger.notifications.error("Sentinel notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// An energy finding that needs attention; clicking it opens Energy.
    func notify(energy finding: EnergyFinding) async {
        guard notificationCenterAvailable else { return }
        switch await currentStatus() {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = "Energy: worth a look"
        content.subtitle = finding.headline
        content.body = finding.advice
        content.categoryIdentifier = NotificationRouter.energyCategory
        content.userInfo = ["energyFinding": finding.id]
        content.threadIdentifier = "ghost.energy"
        let request = UNNotificationRequest(identifier: "ghost.energy.\(finding.id)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            RadarLogger.notifications.error("Energy notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A startup item appeared while Ghost was running.
    func notify(startupItem item: LaunchItem) async {
        guard notificationCenterAvailable else { return }
        switch await currentStatus() {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = item.severity >= .suspicious ? "Security: suspicious startup item" : "New startup item"
        content.subtitle = "\(item.label) · \(item.scope.label.lowercased())"
        content.body = item.programPath.isEmpty ? item.plistPath : item.programPath
        content.sound = item.severity >= .suspicious ? .defaultCritical : .default
        content.categoryIdentifier = NotificationRouter.sentinelCategory
        content.userInfo = ["sentinelFinding": item.id]
        content.threadIdentifier = "ghost.sentinel"
        let request = UNNotificationRequest(identifier: "ghost.startup.\(item.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func requestAuthorization() async -> Bool {
        guard notificationCenterAvailable else {
            RadarLogger.notifications.info("Skipping notification authorization: process is not a bundled app")
            return false
        }
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            RadarLogger.notifications.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            granted = false
        }
        _ = await authorizationStatus()
        return granted
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard notificationCenterAvailable else {
            return .denied
        }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        cachedStatus = status
        statusCheckedAt = Date()
        return status
    }

    private func currentStatus() async -> UNAuthorizationStatus {
        if let cachedStatus, Date().timeIntervalSince(statusCheckedAt) < statusCacheInterval {
            return cachedStatus
        }
        return await authorizationStatus()
    }

    private func notifyIfNeeded(family: ProcessFamily, at date: Date) async {
        guard notificationCenterAvailable else {
            return
        }
        let id = family.signature.id
        if let last = lastDelivered[id], date.timeIntervalSince(last) < minimumInterval {
            return
        }

        switch await currentStatus() {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            // Ask once per launch when something first deserves an alert, but
            // never wait for the answer: the prompt can stay up unanswered.
            // Answering refreshes the cached status, so a later pass delivers;
            // the popover and Settings offer the prompt again.
            if !didPromptThisLaunch {
                didPromptThisLaunch = true
                Task { _ = await self.requestAuthorization() }
            }
            return
        case .denied:
            // The delivery interval also throttles re-checks for this family.
            lastDelivered[id] = date
            return
        @unknown default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(family.displayName) is \(family.score.level.label.lowercased())"
        content.subtitle = "\(ProcessAssessment(family: family).cause) - \(RadarFormat.bytes(family.totalPhysicalFootprintBytes)) - \(Int(family.totalCPUPercent.rounded()))% CPU"
        content.body = (family.score.heat.evidence.isEmpty ? family.score.reasons : family.score.heat.evidence)
            .prefix(3)
            .joined(separator: ", ")
        content.sound = .default
        content.categoryIdentifier = NotificationRouter.familyCategory
        content.userInfo = ["familyKey": family.familyKey, "signatureID": id, "familyName": family.displayName]
        content.threadIdentifier = id

        // A stable identifier replaces the family's previous alert instead of
        // stacking another copy in Notification Center.
        let request = UNNotificationRequest(identifier: "ghost.\(id)", content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            lastDelivered[id] = date
            RadarLogger.notifications.info("Delivered notification for \(family.displayName, privacy: .public)")
        } catch {
            RadarLogger.notifications.error("Notification delivery failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
