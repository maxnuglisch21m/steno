import Foundation
import StenoCore

/// What happens between "Teams started using the microphone" and "a recording is
/// running": specification §2 from the trigger to the click, and back again at
/// auto-stop.
///
/// The pieces are deliberately kept apart — `MeetingDetector` knows Core Audio and
/// nothing else, `WindowTitleReader` knows window titles and nothing else,
/// `SuggestionPanel` knows AppKit and nothing else — and this is the one object that
/// knows all of them plus the coordinator. It is where the rules that cross those
/// boundaries live:
///
/// 1. **A trigger during a recording is ignored** (specification §1). Not suppressed
///    later, not queued: ignored, in silence. Detection itself keeps running, because
///    the same machinery is what ends the recording.
/// 2. **The question comes first, the name second.** The suggestion is shown the
///    moment the debounce is over, with the generic wording; the title search runs
///    beside it and folds its answer in when it has one — into the panel's text, into
///    the recording that has meanwhile started, or into neither if the user has
///    already said no. It used to run *before* the panel, and a Teams call that takes
///    eight seconds to name its window is eight seconds in which the user sees nothing
///    and the meeting starts without them.
/// 3. **Every ending is reported back to detection**, so that a meeting the user
///    stopped by hand is not offered again while it is still running.
@MainActor
final class MeetingDetectionController {
    private let settings: SettingsStore
    private let appState: AppState
    private let coordinator: RecordingCoordinator
    private let detector: MeetingDetector
    private var titleSource: any MeetingTitleSource
    private let panel: SuggestionPanel

    /// How long the suggestion stays up. Specification §2's twenty seconds; shortened
    /// by `--suggestion-timeout` when a debug run cannot wait.
    var suggestionTimeout: TimeInterval = SuggestionPanel.defaultTimeout

    /// The meeting a decision is currently being made about, or the one whose title is
    /// still being chased after the decision was made.
    private var pending: Pending?
    private var titleTask: Task<Void, Never>?

    /// One trigger, from the panel going up until the title search gives up.
    private struct Pending {
        var meeting: DetectedMeeting
        /// The title, once the window search has found one.
        var title: String?
        /// Whether the user said yes and a recording of this meeting was started.
        var didStart = false
        /// Whether the question has been answered at all, either way.
        var isAnswered = false
    }

    init(
        settings: SettingsStore,
        appState: AppState,
        coordinator: RecordingCoordinator,
        detector: MeetingDetector,
        titleSource: any MeetingTitleSource,
        panel: SuggestionPanel = .shared
    ) {
        self.settings = settings
        self.appState = appState
        self.coordinator = coordinator
        self.detector = detector
        self.titleSource = titleSource
        self.panel = panel
    }

    // MARK: - Running

    func start() {
        detector.onMeetingStarted = { [weak self] meeting in
            self?.handleMeetingStarted(meeting)
        }
        detector.onMeetingEnded = { [weak self] app in
            self?.handleMeetingEnded(app)
        }
        coordinator.onRecordingEnded = { [weak self] bundleId in
            self?.handleRecordingEnded(bundleId)
        }
        detector.start()
    }

    func stop() {
        titleTask?.cancel()
        titleTask = nil
        pending = nil
        panel.dismiss()
        detector.stop()
    }

    // MARK: - A meeting started

    private func handleMeetingStarted(_ meeting: DetectedMeeting) {
        // Specification §1: "Läuft eine Aufnahme, werden neue Auslöser ignoriert."
        // Quietly — the user is in a meeting and does not need a menu notice about a
        // second one.
        if appState.phase.isRecording || appState.phase.isProcessing {
            Log.detection.notice(
                "trigger for \(meeting.name, privacy: .public) ignored: a recording is already running or being processed"
            )
            return
        }
        guard pending == nil else {
            Log.detection.debug("a decision is already in flight; ignoring the second trigger")
            return
        }

        pending = Pending(meeting: meeting)
        // The panel first, and in the same turn of the run loop as the trigger: this
        // is the latency the user actually feels.
        panel.show(appName: meeting.name, title: nil, timeout: suggestionTimeout) { [weak self] answer in
            self?.handleAnswer(answer, for: meeting)
        }
        startTitleSearch(for: meeting)
    }

    /// Chases the window title beside the panel and delivers it wherever it still
    /// matters.
    private func startTitleSearch(for meeting: DetectedMeeting) {
        titleTask?.cancel()
        titleTask = Task { [weak self] in
            guard let self else { return }
            let title = await self.titleSource.title(for: meeting)
            guard !Task.isCancelled else { return }
            self.applyTitle(title, to: meeting)
        }
    }

    /// A title arrived. Where it goes depends on what has happened in the meantime.
    private func applyTitle(_ title: String?, to meeting: DetectedMeeting) {
        defer { titleTask = nil }
        guard var current = pending, current.meeting.bundleId == meeting.bundleId else { return }
        guard let title, !title.isEmpty else {
            // Nothing found in ten seconds. The panel keeps the generic wording, and a
            // recording that started keeps a folder named after the app alone.
            if current.isAnswered { pending = nil }
            return
        }

        current.title = title
        pending = current
        // The title itself is never logged — `Log`'s rule is that no meeting content
        // reaches the unified log.
        Log.detection.notice(
            """
            window title for \(meeting.name, privacy: .public) found \
            \(current.isAnswered ? "after" : "before", privacy: .public) the answer
            """
        )

        if !current.isAnswered {
            // Still on screen: the sentence gains the meeting's name where the user
            // can see it before deciding.
            panel.updateTitle(title)
        } else if current.didStart {
            // Too late for the folder name, which was fixed when the folder was
            // created, but not too late for `meta.json` — and `meta.title` is what a
            // reader downstream actually looks at.
            coordinator.setTitle(title)
        }
        if current.isAnswered { pending = nil }
    }

    // MARK: - The answer

    private func handleAnswer(_ answer: SuggestionPanel.Answer, for meeting: DetectedMeeting) {
        guard var current = pending, current.meeting.bundleId == meeting.bundleId else { return }
        current.isAnswered = true

        switch answer {
        case .record:
            current.didStart = true
            pending = current
            startRecording(meeting, title: current.title)
            // A title still on its way is worth having: it reaches `meta.json` through
            // `applyTitle`. If the search is already over, so is this trigger.
            if titleTask == nil { pending = nil }

        case .ignore:
            // Ignoring is an answer, and the answer holds until the app has been quiet
            // for sixty seconds (specification §2). Nothing to do: the state machine
            // already recorded that it asked, and nobody is waiting for the name of a
            // meeting that will not be recorded.
            Log.detection.notice("suggestion for \(meeting.name, privacy: .public) ignored")
            titleTask?.cancel()
            titleTask = nil
            pending = nil
        }
    }

    /// Starts the recording detection asked about.
    ///
    /// The process list is re-read here rather than reused: between the trigger and
    /// the click a browser has usually opened another helper for the call, and the tap
    /// has to cover the process that is actually playing the meeting. If the app has
    /// no audio processes left at all — the meeting ended during the twenty seconds —
    /// the target falls back to a system-wide tap rather than failing the recording.
    private func startRecording(_ meeting: DetectedMeeting, title: String?) {
        let pids = detector.currentProcesses(of: meeting.app)
        let fresh = DetectedMeeting(app: meeting.app, pids: pids.isEmpty ? meeting.pids : pids)
        Log.detection.notice(
            """
            starting a recording of \(meeting.name, privacy: .public) \
            (\(fresh.tapTarget.logDescription, privacy: .public), \
            title \(title == nil ? "unknown" : "known", privacy: .public))
            """
        )
        coordinator.start(
            mode: .online,
            trigger: fresh.trigger,
            appName: fresh.name,
            title: title,
            tapTarget: fresh.tapTarget
        )
    }

    // MARK: - A meeting ended

    /// Auto-stop. Specification §2: no watched process reading the microphone for
    /// `autoStopDelay` seconds ends the recording.
    ///
    /// Applies to any `online` recording of this app, whether detection started it or
    /// the user did — the question auto-stop answers is "is the meeting over", and how
    /// the recording began does not change the answer. It never applies to `onsite`,
    /// which specification §1 says stops only by hand: a room full of people is not
    /// over because nobody's Mac is using a microphone.
    private func handleMeetingEnded(_ app: WatchedApp) {
        guard case .recording(let mode, _) = appState.phase else { return }
        guard mode == .online else {
            Log.detection.debug("auto-stop does not apply to an onsite recording")
            return
        }
        let recorded = coordinator.recordingBundleId
        // A recording made with a system-wide tap has no app of its own; the meeting
        // that just ended is the only candidate there is, and it is the one that
        // triggered the recording in every path that leads here.
        guard recorded == nil || recorded == app.bundleId else {
            Log.detection.notice(
                """
                \(app.name, privacy: .public) went quiet, but the recording belongs to \
                \(recorded ?? "another app", privacy: .public); not stopping
                """
            )
            return
        }
        Log.detection.notice("auto-stopping the recording of \(app.name, privacy: .public)")
        appState.notice = String(
            format: String(localized: "Automatisch gestoppt: %@ nutzt das Mikrofon nicht mehr."),
            app.name
        )
        coordinator.stop(reason: .auto)
    }

    /// A recording ended, for whatever reason.
    private func handleRecordingEnded(_ bundleId: String?) {
        guard let bundleId else { return }
        detector.forgetMeeting(bundleId)
    }

    // MARK: - Sleep

    /// The Mac is going to sleep with a recording running.
    ///
    /// Stopping is the only honest option: capture is about to end whether Steno
    /// agrees or not, and a folder that says `stopReason: "sleep"` is worth far more
    /// than one whose audio stops mid-sentence with a header that was never finished.
    func handleWillSleep() {
        guard appState.phase.isRecording else { return }
        Log.app.notice("stopping the recording because the Mac is going to sleep")
        appState.notice = String(localized: "Der Mac ist eingeschlafen. Die Aufnahme wurde beendet.")
        coordinator.stop(reason: .sleep)
    }

    // MARK: - Test and simulation hooks

    #if DEBUG
    /// The meeting a decision is being made about, for the debug runs.
    var pendingMeeting: DetectedMeeting? { pending?.meeting }

    /// The title found for it so far, if any.
    var pendingTitle: String? { pending?.title }

    /// Hands the controller a title without a window to read it from.
    /// `--simulate-detection` and the tests, and nothing else.
    func useTitleSource(_ source: any MeetingTitleSource) {
        titleSource = source
    }
    #endif
}
