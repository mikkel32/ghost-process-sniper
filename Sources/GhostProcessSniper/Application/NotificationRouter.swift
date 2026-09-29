import Foundation
import UserNotifications

/// Turns notification clicks and actions into app navigation. Without a
/// delegate a click only activated the accessory app, and macOS suppressed
/// banners while the console was frontmost.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let familyCategory = "ghost.family"
    static let sentinelCategory = "ghost.sentinel"
    static let energyCategory = "ghost.energy"
    static let stopAction = "ghost.stop"
    static let snoozeAction = "ghost.snooze"
    static let showAction = "ghost.show"

    let coordinator: MenuBarCoordinator

    init(coordinator: MenuBarCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    /// Must run before launch finishes so a click that launched the app is delivered.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: Self.stopAction, title: "Stop…", options: [.foreground]),
            UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 1 Hour", options: []),
            UNNotificationAction(identifier: Self.showAction, title: "Show", options: [.foreground])
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.familyCategory, actions: actions, intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.sentinelCategory,
                                   actions: [UNNotificationAction(identifier: Self.showAction, title: "Review", options: [.foreground])],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.energyCategory,
                                   actions: [UNNotificationAction(identifier: Self.showAction, title: "Review", options: [.foreground])],
                                   intentIdentifiers: [], options: [])
        ])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        if userInfo["sentinelFinding"] != nil {
            await coordinator.showSecurityCommand()
            return
        }
        if userInfo["energyFinding"] != nil {
            await coordinator.showEnergyCommand()
            return
        }
        let familyKey = userInfo["familyKey"] as? String
        let signatureID = userInfo["signatureID"] as? String
        let familyName = userInfo["familyName"] as? String
        await coordinator.handleNotification(action: action, familyKey: familyKey, signatureID: signatureID,
                                             familyName: familyName)
    }
}
