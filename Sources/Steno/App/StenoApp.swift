import AppKit
import StenoCore
import SwiftUI

/// The menu-bar app.
///
/// `LSUIElement` is set in `Info.plist`, so there is no Dock icon and no main window.
/// The interface is a status item, a settings window, and an onboarding window —
/// nothing else. The menu is the one from specification §7.
@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The one wired-up instance. Held as a plain property rather than `@State`
    /// because it outlives every view and is never replaced.
    private let environment = AppEnvironment.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(environment: environment)
        } label: {
            MenuBarLabel(appState: environment.appState)
        }
        // `.menu`, not `.window`: the interface is a list of commands, and a menu is
        // what macOS gives keyboard navigation and the standard look to for free.
        .menuBarExtraStyle(.menu)

        // No `Settings` scene: see `SettingsWindowController` for why the settings
        // window is an `NSWindow` this app owns instead.
    }
}

/// Launch, activation, and quit.
///
/// A `MenuBarExtra`-only app still needs a delegate: the hotkeys have to be registered
/// before any window exists, the onboarding window is shown on first launch, and the
/// debug launch arguments have to be read before the run loop settles.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether the app was launched as a test host rather than by the user.
    ///
    /// The test bundle is hosted by this app, so `applicationDidFinishLaunching` runs
    /// before the first test does. Without this guard a test run would create the
    /// user's recording folder, register global hotkeys, mark the onboarding as seen,
    /// and pop the onboarding window — real side effects, on the machine running the
    /// tests, from tests that build their own state anyway.
    private var isRunningTests: Bool { RunningEnvironment.isUnitTesting }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningTests {
            Log.app.debug("launched as a test host; skipping app start-up")
            return
        }
        MainActor.assumeIsolated {
            let environment = AppEnvironment.shared
            #if DEBUG
            let debugArguments = DebugLaunchArguments(CommandLine.arguments)
            // A debug run drives detection itself, or wants it off: a real meeting
            // starting on this Mac must not interrupt what is being measured.
            environment.start(detection: debugArguments.wantsAppDetection)
            #else
            environment.start()
            #endif
            Log.app.notice(
                "Steno \(AppVersion.marketing, privacy: .public) (\(AppVersion.build, privacy: .public)) launched"
            )

            #if DEBUG
            if debugArguments.isActive {
                debugArguments.run(in: environment)
                return
            }
            #endif

            if !environment.settings.hasShownOnboarding {
                environment.settings.hasShownOnboarding = true
                OnboardingWindowController.shared.show(environment: environment)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppEnvironment.shared.stop()
        }
    }

    /// The app has no windows to speak of, so closing the last one must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Version information read off the bundle, so that `meta.json` and the update check
/// agree with what Finder shows.
enum AppVersion {
    /// `CFBundleShortVersionString`, e.g. `0.1.0`.
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `CFBundleVersion`, the build number.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The marketing version parsed, for comparing against an appcast entry.
    static var semantic: SemVer? { SemVer(marketing) }

    /// `26.6.0`, for `meta.json`: a recording made on a different macOS is worth
    /// being able to tell apart afterwards.
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
