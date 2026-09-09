import Foundation
import StenoCore

/// What happens between "Teams started using the microphone" and "a recording is
/// running": specification §2 from the trigger to the click, and back again at
/// auto-stop.
///
/// The pieces are deliberately kept apart — `MeetingDetector` knows Core Audio and
/// nothing else, `RuleEngine` knows rules and nothing else, `SuggestionPanel` knows
/// AppKit and nothing else — and this is the one object that knows all four of them
/// plus the coordinator. It is where the two rules that cross those boundaries live:
///
/// 1. **A trigger during a recording is ignored** (specification §1). Not suppressed
///    later, not queued: ignored, in silence. Detection itself keeps running, because
///    the same machinery is what ends the recording.
/// 2. **Every ending is reported back to detection**, so that a meeting the user
///    stopped by hand is not offered again while it is still running.
@MainActor
final class MeetingDetectionController {
    private let settings: SettingsStore
    private let appState: AppState
    private let coordinator: RecordingCoordinator
    private let detector: MeetingDetector
    let ruleEngine: RuleEngine
    private let panel: SuggestionPanel

    /// How long the suggestion stays up. Specification §2's twenty seconds; shortened
    /// by `--suggestion-timeout` when a debug run cannot wait.
    var suggestionTimeout: TimeInterval = SuggestionPanel.defaultTimeout

    /// The meeting a decision is currently being made about, so a second trigger for
    /// the same app does not open a second panel.
    private var pending: DetectedMeeting?
    private var decisionTask: Task<Void, Never>?

    init(
        settings: SettingsStore,
        appState: AppState,
        coordinator: RecordingCoordinator,
        detector: MeetingDetector,
        ruleEngine: RuleEngine,
        panel: SuggestionPanel = .shared
    ) {
        self.settings = settings
        self.appState = appState
        self.coordinator = coordinator
        self.detector = detector
        self.ruleEngine = ruleEngine
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
        decisionTask?.cancel()
        decisionTask = nil
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

        pending = meeting
        decisionTask = Task { [weak self] in
            guard let self else { return }
            let decision = await self.ruleEngine.decide(for: meeting)
            guard !Task.isCancelled else { return }
            self.apply(decision, to: meeting)
        }
    }

    /// never / ask / always, after the title search has had its say.
    private func apply(_ decision: RuleDecision, to meeting: DetectedMeeting) {
        defer { decisionTask = nil }

        // The title search takes up to ten seconds, and a great deal can happen in
        // ten seconds — the user may have started a recording by hand in the meantime.
        guard !appState.phase.isRecording, !appState.phase.isProcessing else {
            Log.detection.notice("the decision arrived after a recording had started; dropping it")
            pending = nil
            return
        }

        switch decision.action {
        case .never:
            // Nothing is shown and nothing is started. The app stays "offered" as far
            // as the state machine is concerned, so the sixty-second hysteresis
            // applies here exactly as it does to an ignored popup: a `never` rule that
            // re-evaluated every five seconds would burn a title search each time.
            Log.detection.notice(
                "a rule says never to record \(meeting.name, privacy: .public); no suggestion shown"
            )
            pending = nil

        case .always:
            Log.detection.notice("a rule says always to record \(meeting.name, privacy: .public)")
            pending = nil
            startRecording(meeting, title: decision.title)

        case .ask:
            panel.show(
                appName: meeting.name,
                title: decision.title,
                timeout: suggestionTimeout
            ) { [weak self] answer in
                guard let self else { return }
                self.pending = nil
                switch answer {
                case .record:
                    self.startRecording(meeting, title: decision.title)
                case .ignore:
                    // Ignoring is an answer, and the answer holds until the app has
                    // been quiet for sixty seconds (specification §2). Nothing to do:
                    // the state machine already recorded that it asked.
                    Log.detection.notice("suggestion for \(meeting.name, privacy: .public) ignored")
                }
            }
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
            (\(fresh.tapTarget.logDescription, privacy: .public))
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
    var pendingMeeting: DetectedMeeting? { pending }
    #endif
}
