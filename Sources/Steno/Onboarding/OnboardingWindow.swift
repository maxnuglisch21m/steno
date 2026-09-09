import AppKit
import SwiftUI
import UserNotifications

/// The window shown on first launch, and again from Settings → Allgemein.
///
/// An `NSWindowController` rather than a SwiftUI `Window` scene, because it has to be
/// openable from three places that have no `Environment` to reach through — the app
/// delegate at first launch, a settings button, and a debug launch argument — and
/// because it needs to know when it closes so the five-second permission refresh can
/// stop again.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private weak var environment: AppEnvironment?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window, creating it the first time and bringing it forward after.
    func show(environment: AppEnvironment) {
        self.environment = environment

        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            environment.permissions.startPeriodicRefresh()
            return
        }

        let hosting = NSHostingController(rootView: OnboardingView(environment: environment))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Steno einrichten")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setContentSize(NSSize(width: 520, height: 560))
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        // A check mark that only turns green after a click would be a lie: the user
        // grants these in System Settings, in another process.
        environment.permissions.startPeriodicRefresh()
        Task { await environment.permissions.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        environment?.permissions.stopPeriodicRefresh()
    }
}

/// Four rows, one per thing that has to be in place, each with the one button that
/// moves it forward. Specification §8.
struct OnboardingView: View {
    let environment: AppEnvironment

    private var snapshot: PermissionSnapshot { environment.permissions.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Permission.allCases) { permission in
                        PermissionRow(
                            permission: permission,
                            state: snapshot[permission],
                            detail: detail(for: permission),
                            action: { act(on: permission) },
                            actionTitle: actionTitle(for: permission),
                            isActionEnabled: isActionEnabled(for: permission),
                            helpText: helpText(for: permission)
                        )
                    }
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(minWidth: 480, minHeight: 520)
        .task {
            await environment.permissions.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Steno einrichten"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "Steno nimmt Meetings auf und transkribiert sie auf diesem Mac. Dafür braucht es drei Berechtigungen und einmal die Modelle."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Steno schreibt ausschließlich in den Ordner, den du unter „Einstellungen → Allgemein“ auswählst. Ausnahme: die Modelle liegen unter „Library/Application Support/Steno“. Nichts verlässt diesen Mac."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(Dependencies.summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(String(localized: "Fertig")) {
                    // The one moment in the whole app where notification permission is
                    // asked for without the user having flipped the settings toggle:
                    // they have just finished setting Steno up, they have said yes to
                    // three system prompts already, and a transcript that finishes
                    // twenty minutes later has no other way of reaching them. Asked
                    // only when notifications are switched on and macOS has never been
                    // asked before — never at launch, never twice.
                    Task {
                        if environment.settings.settings.notificationsEnabled,
                           await Notifications.shared.authorizationStatus() == .notDetermined {
                            await Notifications.shared.requestAuthorization()
                        }
                        await MainActor.run { NSApp.keyWindow?.close() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: - Per-row behaviour

    private func detail(for permission: Permission) -> String? {
        switch permission {
        case .systemAudio:
            // The probe can fail for reasons that are not an answer; when it does, say so.
            return environment.permissions.systemAudioProbeDetail
        case .screenRecording:
            guard !snapshot.screenRecording.isGranted else { return nil }
            return String(localized: "macOS gibt die Bildschirmaufnahme erst nach einem Neustart von Steno frei.")
        case .models:
            // The one row that says more than "granted" or "missing": a download, a
            // compile that takes minutes, and a warm-up all happen behind it.
            return environment.models.statusDescription
        case .microphone:
            guard snapshot.microphone == .denied else { return nil }
            return String(localized: "In den Systemeinstellungen abgelehnt. Dort wieder erlauben.")
        }
    }

    private func actionTitle(for permission: Permission) -> String {
        // The models are not a permission, so "open System Settings" is the wrong
        // answer for them in either direction: an installed set is shown in the Finder.
        if permission == .models {
            return snapshot.models.isGranted
                ? String(localized: "Modellordner zeigen")
                : String(localized: "Modelle laden")
        }
        if snapshot[permission].isGranted {
            return String(localized: "Systemeinstellungen öffnen")
        }
        switch permission {
        case .models:
            return String(localized: "Modelle laden")
        case .microphone, .systemAudio:
            return snapshot[permission] == .denied
                ? String(localized: "Systemeinstellungen öffnen")
                : String(localized: "Zugriff erlauben")
        case .screenRecording:
            return String(localized: "Zugriff erlauben")
        }
    }

    private func isActionEnabled(for permission: Permission) -> Bool {
        switch permission {
        case .models:
            return environment.models.canDownload
        default:
            return true
        }
    }

    private func helpText(for permission: Permission) -> String {
        switch permission {
        case .models:
            return environment.models.downloadUnavailableReason
        default:
            return ""
        }
    }

    private func act(on permission: Permission) {
        switch permission {
        case .models:
            if snapshot.models.isGranted {
                environment.models.revealModelsDirectory()
            } else {
                Task { try? await environment.models.download() }
            }
        case .microphone, .systemAudio:
            if snapshot[permission].isGranted || snapshot[permission] == .denied {
                permission.openSystemSettings()
            } else {
                Task { await environment.permissions.request(permission) }
            }
        case .screenRecording:
            if snapshot.screenRecording.isGranted {
                permission.openSystemSettings()
            } else {
                Task { await environment.permissions.request(permission) }
            }
        }
    }
}

/// One row: state, title, one sentence, one button.
private struct PermissionRow: View {
    let permission: Permission
    let state: PermissionState
    let detail: String?
    let action: () -> Void
    let actionTitle: String
    let isActionEnabled: Bool
    /// Why the button is disabled, or what it will do. Empty for the obvious cases.
    var helpText: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.isGranted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(state.isGranted ? Color.green : Color.secondary)
                .accessibilityLabel(
                    state.isGranted
                        ? String(localized: "erteilt")
                        : String(localized: "fehlt")
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title)
                    .font(.headline)
                Text(permission.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button(actionTitle, action: action)
                .disabled(!isActionEnabled)
                .help(helpText)
        }
    }
}
