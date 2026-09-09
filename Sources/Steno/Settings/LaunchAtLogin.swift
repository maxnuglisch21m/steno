import Foundation
import ServiceManagement

/// The login item, through `SMAppService`.
///
/// `SMAppService.mainApp` needs no helper bundle and no `LaunchAgents` plist: macOS
/// registers the app itself, and the user can revoke it in System Settings → General
/// → Login Items. That is why `isEnabled` reads the service's status every time
/// instead of trusting a stored flag — the switch is not ours alone.
enum LaunchAtLogin {
    /// Whether macOS will start Steno at login.
    ///
    /// `.requiresApproval` counts as not enabled: the registration exists but the
    /// user has not approved it, so nothing will launch. The settings window says so.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Whether the registration is waiting for the user's approval in System Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            // Registering an already-registered app throws, which is not an error the
            // user needs to see.
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens the Login Items pane, for the case where the registration needs approval.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
