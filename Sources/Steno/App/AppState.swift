import Foundation
import Observation
import StenoCore

/// Everything the menu bar renders, in one observable place.
///
/// The whole interface is a status item and two windows, so there is one state object
/// rather than a view model per view. It holds no logic beyond formatting: what may be
/// started, and what happens when it is, belongs to `RecordingCoordinator`.
@MainActor
@Observable
final class AppState {
    /// What Steno is doing. Specification §7 gives the icon for each of the three.
    enum Phase: Sendable, Equatable {
        /// Nothing running. Microphone outline.
        case idle
        /// Capturing. Filled microphone, red dot, `mm:ss`, plus a room glyph for `onsite`.
        case recording(mode: MeetingMode, started: Date)
        /// Transcribing. Progress ring; `progress` is `nil` while the step has no
        /// measurable share.
        case processing(progress: Double?, label: String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isProcessing: Bool {
            if case .processing = self { return true }
            return false
        }

        var recordingMode: MeetingMode? {
            if case .recording(let mode, _) = self { return mode }
            return nil
        }

        var startedAt: Date? {
            if case .recording(_, let started) = self { return started }
            return nil
        }
    }

    var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            elapsed = phase.isRecording ? Date().timeIntervalSince(phase.startedAt ?? Date()) : 0
            syncTicker()
        }
    }

    /// The permissions, mirrored from `PermissionMonitor` so the menu reads one object.
    var permissions: PermissionSnapshot = .unknown

    /// The newest finished meeting, for "Letztes Meeting im Finder zeigen".
    var lastMeetingURL: URL?

    /// Display name of the app being recorded, for the status line: "Aufnahme läuft ·
    /// Teams · 12:34". `nil` for `onsite` and for an `online` recording with a
    /// system-wide tap, where the mode's own name is all there is to say.
    var recordingAppName: String?

    /// Whether the screen is locked right now.
    ///
    /// Set by `SleepLockObserver`. Audio does not care — a locked Mac keeps recording
    /// the meeting, which is correct — but M4's screenshots do: two hundred images of
    /// the lock wallpaper are two hundred images of nothing.
    var isScreenLocked = false

    /// Seconds since the recording began, updated once a second.
    private(set) var elapsed: TimeInterval = 0

    /// A short sentence for the menu when something needs saying — low disk space, a
    /// root folder that could not be created, a recording that failed.
    var notice: String?

    private var ticker: Timer?

    init() {}

    // MARK: - The clock

    /// `mm:ss`, or `h:mm:ss` past the hour. This is the text next to the menu-bar icon
    /// while recording (specification §7).
    var elapsedClock: String {
        Self.clock(elapsed)
    }

    /// `nonisolated` so the icon renderer, which does its drawing off the main
    /// actor's back, can format the same clock without a hop.
    nonisolated static func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The non-interactive line at the top of the menu while recording:
    /// "Aufnahme läuft · Vor Ort · 12:34".
    var recordingStatusLine: String? {
        guard case .recording(let mode, _) = phase else { return nil }
        // The app's name displaces the mode when one is known: while a Teams call is
        // being recorded, "Teams" says everything "Online" said and one thing more.
        return String(
            format: String(localized: "Aufnahme läuft · %@ · %@"),
            recordingAppName ?? Self.modeName(mode),
            elapsedClock
        )
    }

    nonisolated static func modeName(_ mode: MeetingMode) -> String {
        switch mode {
        case .online: return String(localized: "Online")
        case .onsite: return String(localized: "Vor Ort")
        }
    }

    // MARK: - Ticker

    /// Drives the `mm:ss` in the menu bar.
    ///
    /// A `Timer` on the common run-loop modes rather than a `Task` that sleeps,
    /// because the clock has to keep counting while the menu is open — menu tracking
    /// runs the run loop in its own mode, and a timer added only to the default mode
    /// would freeze for as long as the menu is down.
    private func syncTicker() {
        if phase.isRecording {
            guard ticker == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                // Timers scheduled on the main run loop fire on the main thread, which
                // is where the main actor lives. The compiler cannot see that through
                // `Timer`'s non-isolated closure, so it is asserted here rather than
                // hopping through a `Task` that would make the tick late.
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        guard let started = phase.startedAt else { return }
        elapsed = Date().timeIntervalSince(started)
    }

    /// Stops the ticker. Called when the app quits, so a pending timer does not fire
    /// into a half-torn-down app.
    func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
