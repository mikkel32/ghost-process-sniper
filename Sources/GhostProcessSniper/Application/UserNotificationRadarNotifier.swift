import Foundation
import GhostProcessSniperCore
import UserNotifications

actor UserNotificationRadarNotifier: RadarNotifying {
    private var lastDelivered: [String: Date] = [:]
    private let minimumInterval: TimeInterval = 15 * 60
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

    func requestAuthorization() async -> Bool {
        guard notificationCenterAvailable else {
            RadarLogger.notifications.info("Skipping notification authorization: process is not a bundled app")
            return false
        }
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            RadarLogger.notifications.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard notificationCenterAvailable else {
            return .denied
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    private func notifyIfNeeded(family: ProcessFamily, at date: Date) async {
        guard notificationCenterAvailable else {
            return
        }
        if let last = lastDelivered[family.signature.id], date.timeIntervalSince(last) < minimumInterval {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            guard await requestAuthorization() else {
                return
            }
        case .denied:
            return
        @unknown default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(family.displayName) is \(family.score.level.label.lowercased())"
        content.subtitle = "\(ProcessAssessment(family: family).cause) - \(ByteCountFormatter.gpsMemoryString(family.totalPhysicalFootprintBytes)) - \(Int(family.totalCPUPercent.rounded()))% CPU"
        content.body = (family.score.heat.evidence.isEmpty ? family.score.reasons : family.score.heat.evidence)
            .prefix(3)
            .joined(separator: ", ")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ghost.\(family.signature.commandFingerprint).\(Int(date.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            lastDelivered[family.signature.id] = date
            RadarLogger.notifications.info("Delivered notification for \(family.displayName, privacy: .public)")
        } catch {
            RadarLogger.notifications.error("Notification delivery failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension ByteCountFormatter {
    static func gpsMemoryString(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
