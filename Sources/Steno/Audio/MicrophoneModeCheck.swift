import AVFoundation
import AppKit
import Foundation

/// The microphone mode macOS is applying to every capture on this Mac.
///
/// Mirrored from `AVCaptureDevice.MicrophoneMode` as a plain enum so the decision
/// below can be tested for all three values — the real property is a system-wide
/// setting that lives in Control Center and cannot be set from an app.
enum MicrophoneMode: String, Sendable, Hashable, CaseIterable {
    /// Light processing. Usable for a room, but not what it is best at.
    case standard
    /// Minimal processing, the whole room. What `onsite` wants.
    case wideSpectrum
    /// macOS actively suppresses every voice but the closest one.
    case voiceIsolation

    /// The value written into `meta.input.microphoneMode`.
    var metaValue: String { rawValue }

    /// The name Control Center uses.
    var displayName: String {
        switch self {
        case .standard: return String(localized: "Standard")
        case .wideSpectrum: return String(localized: "Breites Spektrum")
        case .voiceIsolation: return String(localized: "Sprachisolierung")
        }
    }

    init?(_ mode: AVCaptureDevice.MicrophoneMode) {
        switch mode {
        case .standard: self = .standard
        case .wideSpectrum: self = .wideSpectrum
        case .voiceIsolation: self = .voiceIsolation
        @unknown default: return nil
        }
    }
}

/// What the microphone mode means for a recording that is about to start.
enum MicrophoneModeDecision: Sendable, Hashable {
    /// Nothing to say. `.wideSpectrum`, and anything unrecognized.
    case proceed
    /// Record, but put a sentence in the menu. `.standard`.
    case proceedWithHint(String)
    /// Refuse. `.voiceIsolation`.
    case block

    var isBlocking: Bool { self == .block }

    var hint: String? {
        if case .proceedWithHint(let hint) = self { return hint }
        return nil
    }
}

/// Specification §3b.1 — the one check that decides whether an `onsite` recording is
/// worth making at all.
///
/// Voice Isolation is the exact opposite of what a room recording needs: macOS damps
/// every voice except the one closest to the microphone, so the other participants —
/// the reason for recording — arrive attenuated or gone, and no amount of work
/// downstream gets them back. Steno refuses rather than producing a file that looks
/// fine and is useless. `.standard` is merely not ideal, so it records and says so.
///
/// `online` is not gated: there, the user's own voice is what the microphone channel
/// is for, and isolating it is harmless or even helpful. Only `onsite` asks.
enum MicrophoneModeCheck {
    /// The mode macOS is applying right now, or `nil` when it reports something this
    /// build does not know about.
    ///
    /// A class property on `AVCaptureDevice`, not a per-device one: the mode is
    /// system-wide. Reading it costs about 20 ns, which is why the menu can ask on
    /// every redraw rather than caching a value that Control Center can change behind
    /// the app's back.
    static func active() -> MicrophoneMode? {
        MicrophoneMode(AVCaptureDevice.activeMicrophoneMode)
    }

    /// What the user picked, which is not always what is active: Voice Isolation is
    /// only applied while an app is capturing, and some devices do not offer every
    /// mode. Logged alongside the active one, because the two disagreeing is exactly
    /// the situation a confused bug report describes.
    static func preferred() -> MicrophoneMode? {
        MicrophoneMode(AVCaptureDevice.preferredMicrophoneMode)
    }

    /// The decision table. The whole of §3b.1 is these three lines.
    static func decision(for mode: MicrophoneMode?) -> MicrophoneModeDecision {
        switch mode {
        case .wideSpectrum:
            return .proceed
        case .standard:
            return .proceedWithHint(standardHint)
        case .voiceIsolation:
            return .block
        case nil:
            // An unrecognized mode is not a reason to refuse a recording; the two
            // that matter are named explicitly and a future third one is not assumed
            // to be hostile.
            return .proceed
        }
    }

    /// Reads the mode and decides, in one call.
    static func decision() -> MicrophoneModeDecision {
        let active = active()
        Log.audio.info(
            """
            microphone mode: active=\(active?.rawValue ?? "unknown", privacy: .public) \
            preferred=\(preferred()?.rawValue ?? "unknown", privacy: .public)
            """
        )
        return decision(for: active)
    }

    /// The sentence the menu shows while `.standard` is in force.
    static var standardHint: String {
        String(localized: "Mikrofonmodus „Standard“ – „Breites Spektrum“ nimmt den ganzen Raum auf.")
    }

    /// The reason a blocked start gives.
    static var blockedReason: String {
        String(localized: "Sprachisolierung dämpft die anderen Teilnehmer.")
    }

    // MARK: - The dialog

    /// Tells the user why the recording did not start, and offers the one place that
    /// can fix it.
    ///
    /// `showSystemUserInterface(.microphoneModes)` opens the microphone-mode section
    /// of Control Center. There is no API to set the mode — an app may ask for a
    /// preference, but the effective mode is the user's, which is why this is a dialog
    /// with a button rather than a fix Steno applies itself. Nothing is remembered: the
    /// next start attempt reads the mode again, so changing it in Control Center and
    /// pressing record is all it takes.
    @MainActor
    static func presentBlockedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Aufnahme nicht möglich")
        alert.informativeText = String(
            localized: """
            Sprachisolierung dämpft die anderen Teilnehmer. Für eine Raumaufnahme \
            braucht Steno den Mikrofonmodus „Breites Spektrum“ oder „Standard“.
            """
        )
        alert.addButton(withTitle: String(localized: "Mikrofonmodus ändern …"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))

        NSApp.activate()
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            Log.audio.notice("voice isolation alert dismissed")
            return
        }
        Log.audio.notice("opening the system microphone-mode interface")
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}
