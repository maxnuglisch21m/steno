import AppKit
import Foundation
import StenoCore

/// Asks how many people are in the room, before an `onsite` recording starts.
///
/// Specification §3b: the diarizer finds the speaker count on its own, and the offline
/// diarizer does accept an upper and a lower bound — so when the user knows the number,
/// telling it is free accuracy on the hardest part of a room recording. Acceptance test
/// B.5 is exactly this: four people at a table have to come out as four speakers, not
/// two and not eight.
///
/// Off by default and behind a setting, because the honest default is "the model
/// decides" and a dialog in front of every recording is a tax on the common case.
@MainActor
enum SpeakerCountPrompt {
    /// What the user chose.
    enum Choice: Sendable, Equatable {
        /// Start, with this many speakers expected, or `nil` for automatic.
        case start(expected: Int?)
        /// Do not record.
        case cancel
    }

    /// The value that means "let the diarizer decide", as the pop-up's first item.
    private static let automaticTag = 0

    /// Shows the dialog and waits. Returns `.cancel` when the user backs out, which
    /// aborts the recording before any folder is created.
    static func ask() -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Wie viele Personen sind im Raum?")
        alert.informativeText = String(
            localized: """
            Die Sprechertrennung findet die Zahl selbst. Wenn du sie kennst, wird sie \
            zuverlässiger.
            """
        )
        alert.addButton(withTitle: String(localized: "Aufnahme starten"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        alert.accessoryView = popUpButton()
        // The pop-up, not the default button, should have the keyboard: the number is
        // the only thing being asked for.
        alert.window.initialFirstResponder = alert.accessoryView

        NSApp.activate()
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            Log.app.notice("speaker count prompt cancelled; no recording started")
            return .cancel
        }

        let tag = (alert.accessoryView as? NSPopUpButton)?.selectedTag() ?? automaticTag
        let expected = tag == automaticTag ? nil : tag
        Log.app.notice(
            "expected speakers: \(expected.map(String.init) ?? "automatic", privacy: .public)"
        )
        return .start(expected: expected)
    }

    private static func popUpButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 25))
        button.addItem(withTitle: String(localized: "Automatisch"))
        button.lastItem?.tag = automaticTag
        for count in SpeakerHint.allowedRange {
            button.addItem(withTitle: "\(count)")
            button.lastItem?.tag = count
        }
        button.selectItem(at: 0)
        return button
    }
}
