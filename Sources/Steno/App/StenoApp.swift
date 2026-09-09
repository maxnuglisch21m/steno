import AppKit
import StenoCore
import SwiftUI

/// The menu-bar app.
///
/// `LSUIElement` is set in `Info.plist`, so there is no Dock icon and no window —
/// `MenuBarExtra` is the whole of the interface. The menu grows into the one from
/// specification §7 in M0; for now it holds the one item every version needs.
@main
struct StenoApp: App {
    var body: some Scene {
        MenuBarExtra("Steno", systemImage: "mic") {
            MenuBarContent()
        }
    }
}

struct MenuBarContent: View {
    var body: some View {
        Button("Beenden") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
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
}
