import AppKit
import StenoCore
import SwiftUI

/// The status-item image, kept in its own view so that observing `AppState` redraws
/// only this and not the whole menu.
struct MenuBarLabel: View {
    let appState: AppState

    var body: some View {
        // Reading `phase` and `elapsed` here is what subscribes the label to them.
        Image(nsImage: MenuBarIconRenderer.image(for: appState.phase, elapsed: appState.elapsed))
    }
}

/// The menu, exactly as specification §7 lists it, plus the two items the plan adds:
/// "Aufnahme stoppen ⌥⌘S" and "Nach Updates suchen …".
struct MenuBarView: View {
    let environment: AppEnvironment

    private var appState: AppState { environment.appState }
    private var coordinator: RecordingCoordinator { environment.coordinator }

    var body: some View {
        // A recording in progress says so at the top, and neither line is a command.
        // The notice sits below the status rather than instead of it, because the
        // microphone-mode hint from specification §3b.1 has to stay readable for the
        // whole recording it applies to — that is the "Hinweis im Menü" the spec asks
        // for, and it would be invisible if the clock displaced it.
        if let status = appState.recordingStatusLine {
            Text(status)
        }
        if let notice = appState.notice {
            Text(notice)
        }
        if appState.recordingStatusLine != nil || appState.notice != nil {
            Divider()
        }

        recordButton(for: .online, action: coordinator.startOnline)
            .keyboardShortcut("r", modifiers: [.option, .command])

        recordButton(for: .onsite, action: coordinator.startOnsite)
            .keyboardShortcut("v", modifiers: [.option, .command])

        if appState.phase.isRecording {
            Button(String(localized: "Aufnahme stoppen")) {
                coordinator.stop()
            }
            .keyboardShortcut("s", modifiers: [.option, .command])
        }

        Divider()

        Button(String(localized: "Letztes Meeting im Finder zeigen")) {
            if let url = appState.lastMeetingURL {
                environment.store.revealInFinder(url)
            }
        }
        .disabled(appState.lastMeetingURL == nil)
        .help(
            appState.lastMeetingURL == nil
                ? String(localized: "Noch kein Meeting aufgenommen.")
                : appState.lastMeetingURL?.lastPathComponent ?? ""
        )

        // Only for a meeting that ended in `failed`. A transcript that is already
        // written has nothing to redo, and offering it anyway would invite the user to
        // overwrite a good transcript with the same one.
        if appState.canReprocessLastMeeting {
            Button(String(localized: "Letztes Meeting erneut verarbeiten")) {
                if let url = appState.lastMeetingURL {
                    environment.transcription.reprocess(url)
                }
            }
            .help(String(localized: "Spracherkennung und Sprechertrennung noch einmal starten."))
        }

        Button(String(localized: "Ordner öffnen")) {
            environment.store.openRootFolder(environment.settings.rootFolderURL)
        }

        Divider()

        // Sparkle is wired up in M7. The item is present so the menu is the one the
        // plan describes, and disabled because the public key in Info.plist is still a
        // placeholder — instantiating the updater now would put an error dialog in
        // front of the user on the first check.
        Button(String(localized: "Nach Updates suchen …")) {}
            .disabled(true)
            .help(String(localized: "verfügbar ab der ersten Veröffentlichung"))

        Button(String(localized: "Einstellungen …")) {
            SettingsWindowController.shared.show(environment: environment)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button(String(localized: "Beenden")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// A record item, disabled with the reason in its title when it cannot be used.
    ///
    /// Specification §8: "Fehlt eine, ist der Aufnahme-Knopf deaktiviert und sagt,
    /// welche" — so the reason goes into the title, where it is always visible, and
    /// into the help text, where the full sentence fits.
    @ViewBuilder
    private func recordButton(for mode: MeetingMode, action: @escaping () -> Void) -> some View {
        let blocker = coordinator.canStart(mode: mode)
        // "Already recording" is a state, not a fault: the item is simply disabled,
        // without a reason bolted onto its title.
        let reason: String? = {
            switch blocker {
            case .none, .some(.alreadyRecording), .some(.processing): return nil
            case .some(let blocker): return blocker.localizedReason
            }
        }()

        Button {
            action()
        } label: {
            if let reason {
                Text(verbatim: "\(Self.title(for: mode)) — \(reason)")
            } else {
                Text(Self.title(for: mode))
            }
        }
        .disabled(blocker != nil)
        .help(blocker?.localizedReason ?? Self.help(for: mode))
    }

    private static func title(for mode: MeetingMode) -> String {
        switch mode {
        case .online: return String(localized: "Online-Meeting aufnehmen")
        case .onsite: return String(localized: "Vor-Ort-Meeting aufnehmen")
        }
    }

    private static func help(for mode: MeetingMode) -> String {
        switch mode {
        case .online:
            return String(localized: "Nimmt Systemton und Mikrofon getrennt auf.")
        case .onsite:
            return String(localized: "Nimmt das Raummikrofon auf. Teilnehmer informieren.")
        }
    }
}
