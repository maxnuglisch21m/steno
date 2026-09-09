import AppKit
import Foundation
import UserNotifications

/// The one place `UNUserNotificationCenter` is touched.
///
/// Notifications are the plan's addition to specification §5: a transcript that
/// finishes twenty minutes after the meeting is a transcript nobody notices, and a
/// recording that failed is worth interrupting for. Both post from here.
///
/// **Authorization is never requested on its own.** `requestAuthorization()` is called
/// from exactly two places — the onboarding window's finish button and the Settings
/// toggle — and from nowhere else, ever. Everything else asks
/// `UNUserNotificationCenter.getNotificationSettings`, which never prompts, and stays
/// quiet unless the answer is `authorized` or `provisional`. A menu-bar app that opens
/// a system prompt at launch, before the user has done anything, is one the user
/// denies out of reflex — and then never sees a notification again.
@MainActor
final class Notifications: NSObject {
    static let shared = Notifications()

    /// The action attached to every notification: "Im Finder zeigen".
    nonisolated static let showInFinderActionIdentifier = "de.21m.steno.show-in-finder"
    /// The category the action hangs off.
    nonisolated static let categoryIdentifier = "de.21m.steno.meeting"
    /// `userInfo` key carrying the folder to reveal.
    nonisolated static let folderKey = "folder"

    /// Whether notifications can be used at all.
    ///
    /// `UNUserNotificationCenter.current()` raises — not throws, raises — for a
    /// process without a bundle identifier, which is what a command-line test host is.
    /// Asking first is cheaper than crashing.
    var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    private var center: UNUserNotificationCenter? {
        isSupported ? UNUserNotificationCenter.current() : nil
    }

    private var isPrepared = false

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Installs the delegate and registers the "Im Finder zeigen" category.
    ///
    /// Neither prompts. Called at launch so that a notification posted later already
    /// has its action, and so that tapping one lands in `didReceive` below rather than
    /// merely bringing an app with no windows to the front.
    func prepare() {
        guard !isPrepared, let center else { return }
        isPrepared = true
        center.delegate = self
        let show = UNNotificationAction(
            identifier: Self.showInFinderActionIdentifier,
            title: String(localized: "Im Finder zeigen"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [show],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - Authorization

    /// Reads the current authorization. Never prompts.
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// Asks macOS for permission to post notifications.
    ///
    /// The only two callers are the onboarding window's finish button and the Settings
    /// toggle — both moments where the user has just said they want this. Returns
    /// whether it was granted, so the toggle can put itself back if it was not.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        prepare()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Log.app.notice("notification authorization \(granted ? "granted" : "refused", privacy: .public)")
            return granted
        } catch {
            Log.app.error(
                "notification authorization failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Posting

    /// Posts one notification, if it is allowed to.
    ///
    /// - Parameters:
    ///   - title: the bold line.
    ///   - body: one sentence under it.
    ///   - folder: the meeting folder "Im Finder zeigen" reveals, if there is one.
    ///   - isEnabled: `settings.notificationsEnabled`. Passed in rather than read here,
    ///     so this file needs nothing from the settings store.
    func post(title: String, body: String, folder: URL?, isEnabled: Bool) async {
        guard isEnabled, let center else { return }
        prepare()

        // Asked every time rather than cached: the user can revoke this in System
        // Settings between two meetings, and posting into a void would be a silent
        // failure that looks exactly like a transcript that never finished.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            Log.app.info(
                "notification not posted: authorization is \(String(describing: status), privacy: .public)"
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        if let folder {
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [Self.folderKey: folder.stenoPath]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            // `nil` means "now". A time interval trigger would delay it for no reason.
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Log.app.error("could not post a notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    /// Shows the banner even when Steno is the frontmost app.
    ///
    /// Without this, macOS suppresses notifications from the app the user is looking
    /// at — reasonable for a mail client, wrong for a menu-bar app whose window may be
    /// open while the transcript finishes.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// "Im Finder zeigen", and a tap on the notification body, both reveal the folder.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let path = response.notification.request.content.userInfo[Notifications.folderKey] as? String
        guard let path else { return }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}
