import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginController {
    /// `.requiresApproval` means registration worked but macOS waits for the
    /// user in System Settings › General › Login Items.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled {
            if status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
