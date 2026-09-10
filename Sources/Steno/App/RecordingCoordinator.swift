import AppKit
import Foundation
import StenoCore

/// Why a recording cannot start right now.
///
/// Specification §8: when a permission is missing, the record item is disabled and
/// says which one. This is the value the menu turns into that sentence, and the same
/// value the hotkeys and the suggestion popup (M3) will consult.
enum StartBlocker: Sendable, Equatable {
    /// A recording is already running. New triggers are ignored (specification §1).
    case alreadyRecording
    /// The previous meeting is still being transcribed.
    case processing
    /// One of the permissions from §8 is not in place.
    case missingPermission(Permission)
    /// Not enough room on the volume to finish an hour.
    case notEnoughDiskSpace(freeBytes: Int64)
    /// The recording root could not be created.
    case rootFolderUnavailable(String)
    /// macOS Voice Isolation is active, which would damp everyone but the nearest
    /// speaker. Specification §3b.1, `onsite` only.
    case voiceIsolationActive

    /// The sentence the menu item and the alert both show.
    var localizedReason: String {
        switch self {
        case .alreadyRecording:
            return String(localized: "Es läuft bereits eine Aufnahme.")
        case .processing:
            return String(localized: "Das letzte Meeting wird noch verarbeitet.")
        case .missingPermission(let permission):
            return String(
                format: String(localized: "Berechtigung fehlt: %@"),
                permission.title
            )
        case .notEnoughDiskSpace(let freeBytes):
            return String(
                format: String(localized: "Zu wenig Speicherplatz: nur noch %@ frei."),
                DiskSpace.formatted(freeBytes)
            )
        case .rootFolderUnavailable(let detail):
            return detail
        case .voiceIsolationActive:
            return MicrophoneModeCheck.blockedReason
        }
    }

    /// The permission to point the user at, when that is what is wrong.
    var permission: Permission? {
        if case .missingPermission(let permission) = self { return permission }
        return nil
    }
}

/// Starts and stops recordings, and keeps `AppState` and `meta.json` in step.
///
/// This is the only place that decides a recording begins or ends. The audio itself
/// arrives through `AudioRecorder` — `MicRecorder` for `onsite`, `ProcessTapRecorder`
/// for `online`, `NullRecorder` for the tests — so the flow below (folder, `meta.json`
/// at every state change, disk check, `mm:ss`, hotkeys) is one path regardless of what
/// is being recorded.
@MainActor
final class RecordingCoordinator {
    /// How long a recorder is given to open the hardware before the recording is
    /// declared failed.
    ///
    /// Nothing in Core Audio has a timeout of its own. A wedged `coreaudiod` — which
    /// is a real state a Mac gets into — makes `AudioDeviceCreateIOProcID` block
    /// forever, and without this the coordinator would sit in `isTransitioning` with
    /// the menu frozen until the app was killed. Fifteen seconds is far longer than
    /// any healthy handshake, which takes tens of milliseconds and, on a busy machine,
    /// occasionally a few seconds.
    static let defaultRecorderTimeout: Duration = .seconds(15)

    /// The deadline for opening the hardware, and the one for closing it. A stop that
    /// hangs must still leave a finished folder behind.
    private(set) var recorderStartTimeout = RecordingCoordinator.defaultRecorderTimeout
    private(set) var recorderStopTimeout = RecordingCoordinator.defaultRecorderTimeout

    private let appState: AppState
    private let settings: SettingsStore
    private let store: RecordingStore
    private(set) var recorderFactory: any RecorderFactory

    /// Where a finished folder goes. Set by `AppEnvironment` at launch.
    ///
    /// Weak and optional so that the recording flow can be built and tested without a
    /// transcription queue, models, or a two-gigabyte checkpoint on disk — and so that
    /// the coordinator never becomes the thing that owns the queue.
    weak var transcription: (any TranscriptionEnqueuing)?

    /// Set while the hardware is being opened, so a second hotkey press during the
    /// handshake does not open a second recording.
    private var isStarting = false
    /// Set while the file is being closed and `meta.json` finished.
    private var isStopping = false
    /// A stop that arrived while a start was still in flight, to be honoured as soon
    /// as the recording exists.
    ///
    /// Opening a microphone takes a moment, and ⌥⌘R immediately followed by ⌥⌘S is a
    /// thing people do. Dropping that stop would leave a recording running that the
    /// user believes they have stopped — so it is remembered instead.
    private var pendingStop = false

    /// Whether a start or a stop is in flight.
    private var isTransitioning: Bool { isStarting || isStopping }

    /// Bundle identifier and name of the app the running recording belongs to, for
    /// the status line and for auto-stop.
    ///
    /// Set for every `online` recording that could name an app, whether detection
    /// started it or the user did: auto-stop asks "is the meeting this recording is of
    /// over", and a manual recording of a Teams call is still a recording of a Teams
    /// call.
    private(set) var recordingBundleId: String?

    /// Called when a recording has finished, for any reason, with the bundle
    /// identifier it belonged to. Detection uses it to forget a meeting it offered.
    var onRecordingEnded: ((String?) -> Void)?

    /// Why the recording that is being stopped is being stopped. Set by `stop`, read
    /// by the code that writes `meta.json`, cleared afterwards.
    private var pendingStopReason: MeetingStopReason = .manual

    private var session: RecordingSession?
    /// The recorder of the running recording. Opened per recording, because holding a
    /// microphone between meetings is both wasteful and visible in the menu bar.
    private var recorder: (any AudioRecorder)?
    /// Screenshots of every display, for the length of the recording (§4). Both modes:
    /// specification §1 records them for `onsite` too, because the screen rarely
    /// changes there and it therefore costs almost nothing.
    private let capturer = ScreenshotCapturer()
    /// Starting the streams takes a moment — one `SCShareableContent` fetch — and the
    /// recording does not wait for it. This is what the stop waits on instead, so that
    /// `meta.displays` is written before `meta.json` is finished.
    private var screenshotStartTask: Task<Void, Never>?
    /// The low-space alert is shown once per launch, not once per recording.
    private var hasWarnedAboutDiskSpace = false

    init(
        appState: AppState,
        settings: SettingsStore,
        store: RecordingStore,
        recorderFactory: any RecorderFactory
    ) {
        self.appState = appState
        self.settings = settings
        self.store = store
        self.recorderFactory = recorderFactory
    }

    /// Convenience for the tests and for `--simulate-null-recording`: one recorder for
    /// both modes.
    convenience init(
        appState: AppState,
        settings: SettingsStore,
        store: RecordingStore,
        recorder: any AudioRecorder
    ) {
        self.init(
            appState: appState,
            settings: settings,
            store: store,
            recorderFactory: FixedRecorderFactory(recorder)
        )
    }

    #if DEBUG
    /// Swaps the recorder source. Only `--simulate-null-recording` uses it: the app
    /// environment is built before the command line is read, and a debug run that
    /// wants no hardware has to be able to say so afterwards.
    func useRecorderFactory(_ factory: any RecorderFactory) {
        guard !appState.phase.isRecording else { return }
        recorderFactory = factory
    }

    /// Forces the `online` tap onto one app, whatever detection would have picked.
    /// `--tap-target <bundle id>`, and nothing else, sets this.
    var forcedTapTargetBundleId: String?

    /// Skips the permission gate for a debug run.
    ///
    /// The simulations fake the permission snapshot, but the permission monitor keeps
    /// refreshing in the background and overwrites it a second later — which is fine
    /// for a run that starts immediately and fatal for one that waits five seconds for
    /// a debounce and a popup. This says "the gate is not what is being tested here",
    /// once, in one place, in debug builds only.
    var ignoresPermissionGate = false

    /// Shortens the two deadlines, so the timeout paths can be tested in under a
    /// second rather than in half a minute. Tests only.
    func setRecorderTimeouts(start: Duration, stop: Duration) {
        recorderStartTimeout = start
        recorderStopTimeout = stop
    }

    /// Logs every screenshot gate decision — display, active, changed share, verdict.
    /// `--screenshot-log`, and nothing else, sets this.
    var logsScreenshotDecisions = false
    #endif

    // MARK: - May we?

    /// The first thing standing in the way of a recording, or `nil` when nothing is.
    ///
    /// The order is deliberate: state first, because "already recording" is not a
    /// problem the user has to fix; then permissions, which is what §8 asks the menu to
    /// name; then the disk; then the microphone mode, which is `onsite`'s alone.
    ///
    /// The microphone mode is read fresh on every call rather than cached. It lives in
    /// Control Center and can change while Steno's menu is open, and reading it costs
    /// about 20 ns — so the menu item enables and disables itself as soon as the menu
    /// is opened again, with no notification to subscribe to and no stale value to
    /// invalidate.
    func canStart(mode: MeetingMode) -> StartBlocker? {
        if appState.phase.isRecording || isTransitioning { return .alreadyRecording }
        if appState.phase.isProcessing { return .processing }

        let requirement: MeetingModeRequirement = mode == .online ? .online : .onsite
        var checksPermissions = true
        #if DEBUG
        checksPermissions = !ignoresPermissionGate
        #endif
        if checksPermissions, let missing = appState.permissions.firstMissing(for: requirement) {
            return .missingPermission(missing)
        }

        let root = settings.rootFolderURL
        if let bytes = DiskSpace.availableBytes(at: root), bytes < DiskSpace.refuseBelow {
            return .notEnoughDiskSpace(freeBytes: bytes)
        }

        // §3b.1 is an `onsite` rule only: in `online` mode the microphone channel is
        // the user's own voice, and isolating it does no harm. Asked through the
        // silent variant, because this runs on every menu redraw and a log line per
        // redraw would bury the one that matters, written when a recording starts.
        if mode == .onsite, MicrophoneModeCheck.decision(for: MicrophoneModeCheck.active()).isBlocking {
            return .voiceIsolationActive
        }
        return nil
    }

    // MARK: - Starting

    func startOnline() {
        start(mode: .online, trigger: .manual)
    }

    func startOnsite() {
        start(mode: .onsite, trigger: .manual)
    }

    /// Starts a recording, or does nothing and says why.
    ///
    /// `appName` and `title` come from detection in M3. Both are `nil` for a manual
    /// start; `online` then works out its own tap target and takes the app name from
    /// whatever turned out to be tapped, or falls back to `…_Online`, and `onsite` is
    /// always `…_Vorort`.
    func start(
        mode: MeetingMode,
        trigger: MeetingTrigger,
        appName: String? = nil,
        title: String? = nil,
        tapTarget: TapTarget? = nil
    ) {
        if let blocker = canStart(mode: mode) {
            // A trigger arriving during a recording is ignored in silence, per
            // specification §1; everything else is worth a line in the log and a note
            // in the menu.
            if blocker == .alreadyRecording {
                Log.app.debug("start ignored: a recording is already running")
            } else {
                Log.app.notice("start refused: \(blocker.localizedReason, privacy: .public)")
                appState.notice = blocker.localizedReason
            }
            // Voice Isolation is the one blocker the user can undo in ten seconds and
            // has no way of guessing at, so it gets a dialog with the button that
            // opens the right place — specification §3b.1.
            if blocker == .voiceIsolationActive {
                MicrophoneModeCheck.presentBlockedAlert()
            }
            return
        }

        var expectedSpeakers: Int?
        // §3b.1 again, the non-blocking half: `standard` records, and says so in the
        // menu for as long as the recording runs.
        var microphoneHint: String?
        if mode == .onsite {
            microphoneHint = MicrophoneModeCheck.decision().hint
            appState.notice = microphoneHint

            if settings.settings.showSpeakerCountPicker {
                switch SpeakerCountPrompt.ask() {
                case .cancel:
                    return
                case .start(let expected):
                    expectedSpeakers = expected
                }
            }
        }

        isStarting = true
        pendingStop = false
        let speakers = expectedSpeakers
        let hint = microphoneHint
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isStarting = false
                self.honourPendingStop()
            }
            await self.beginRecording(
                mode: mode,
                trigger: trigger,
                appName: appName,
                title: title,
                tapTarget: tapTarget,
                expectedSpeakers: speakers,
                microphoneHint: hint
            )
        }
    }

    private func beginRecording(
        mode: MeetingMode,
        trigger: MeetingTrigger,
        appName: String?,
        title: String?,
        tapTarget requestedTapTarget: TapTarget?,
        expectedSpeakers: Int?,
        microphoneHint: String?
    ) async {
        let started = Date()
        let root = settings.rootFolderURL

        if case .failure(let error) = store.ensureRootExists(root) {
            appState.notice = error.localizedDescription
            return
        }

        // Fresh, not cached: this is the moment the number actually decides something.
        warnIfDiskSpaceIsLow(at: root, bytes: DiskSpace.availableBytesNow(at: root))

        // What the `online` tap will capture, and what that makes the folder and
        // `meta.trigger` say. `onsite` has no tap and the value is ignored.
        var tapTarget = TapTarget.systemWide
        var resolvedAppName = appName
        var resolvedTrigger = trigger
        if mode == .online {
            // Detection (M3) has already worked out which processes belong to the
            // meeting and passes them in; a manual start asks the HAL here.
            tapTarget = requestedTapTarget ?? resolveOnlineTapTarget()
            if let name = tapTarget.appName {
                // Detection (M3) names the app itself and wins; a manual start takes
                // the name from whichever app turned out to be tapped.
                resolvedAppName = appName ?? name
                if resolvedTrigger.bundleId == nil {
                    resolvedTrigger.bundleId = tapTarget.bundleId
                    resolvedTrigger.name = name
                }
            }
        }

        let folder = store.meetingFolderURL(
            in: root,
            started: started,
            mode: mode,
            appName: resolvedAppName,
            title: settings.settings.includeTitleInFolderName ? title : nil
        )

        // `meta.json` is written before the first audio frame, so a crash a second
        // later still leaves a folder that says what it was.
        let meta = MeetingMeta(
            mode: mode,
            started: started,
            trigger: resolvedTrigger,
            input: AudioInputInfo(
                device: AudioInputDevices.displayName(forUID: settings.settings.onsiteInputDeviceUID)
            ),
            app: AppVersion.marketing,
            state: .recording,
            title: title,
            appBuild: AppVersion.build,
            os: AppVersion.osVersion,
            // Written from the first second, so a recording interrupted before it
            // finished still carries the number the user gave into the diarizer.
            speakers: expectedSpeakers.map { SpeakerHint(expected: $0) }
        )

        let newSession: RecordingSession
        do {
            newSession = try RecordingSession(folder: folder, meta: meta)
        } catch {
            Log.storage.error("could not create meeting folder: \(error.localizedDescription, privacy: .public)")
            appState.notice = String(
                format: String(localized: "Der Meeting-Ordner ließ sich nicht anlegen: %@"),
                error.localizedDescription
            )
            return
        }

        // A fresh recorder per recording, chosen by mode: `AVAudioEngine` for `onsite`,
        // and — from M2 — a process tap plus an aggregate device for `online`.
        let newRecorder = recorderFactory.recorder(for: mode)
        // The recorder calls this from whatever thread noticed — an audio thread, the
        // writer queue — so the hop back to the main actor happens here rather than in
        // every recorder. Weakly, because the coordinator outliving this closure is
        // the normal case and the reverse would keep a finished recording alive.
        let onInterruption: @Sendable (AudioInterruptionReason) -> Void = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.handleInterruption(reason)
            }
        }

        let configuration = AudioRecorderConfiguration(
            mode: mode,
            folder: folder,
            inputDeviceUID: settings.settings.onsiteInputDeviceUID,
            started: started,
            tapTarget: tapTarget,
            onInterruption: onInterruption
        )
        // Under a deadline, because a hung audio daemon has no other way out: see
        // `recorderStartTimeout`.
        switch await Deadline.run(recorderStartTimeout, operation: { try await newRecorder.start(configuration) }) {
        case .finished(.success(let opened)):
            try? newSession.update { meta in
                meta.input = AudioInputInfo(
                    device: opened.deviceName,
                    microphoneMode: opened.microphoneMode
                )
            }
        case .finished(.failure(let error)):
            Log.audio.error("recorder refused to start: \(error.localizedDescription, privacy: .public)")
            newSession.fail(reason: error.localizedDescription)
            newSession.releaseLock()
            appState.notice = error.localizedDescription
            notifyFailure(reason: error.localizedDescription, folder: newSession.folder)
            return
        case .timedOut(let task):
            let reason = RecorderTimeout.start.localizedDescription
            Log.audio.error("the recorder did not answer within 15 s; giving up on this recording")
            abandon(start: task, recorder: newRecorder, folder: folder)
            newSession.fail(reason: reason)
            newSession.releaseLock()
            appState.notice = reason
            return
        }

        session = newSession
        recorder = newRecorder
        // Right after the recorder: the screenshots belong to the same recording, and
        // nothing about them may hold up or fail the audio.
        startScreenshots(session: newSession, started: started)
        recordingBundleId = resolvedTrigger.bundleId ?? tapTarget.bundleId
        pendingStopReason = .manual
        appState.recordingAppName = mode == .online ? resolvedAppName : nil
        appState.phase = .recording(mode: mode, started: started)
        // Nothing needs saying about a recording that started — except the
        // microphone-mode hint, which stays up for as long as it runs.
        appState.notice = microphoneHint
        Log.app.notice(
            "recording started: \(mode.rawValue, privacy: .public) in \(folder.lastPathComponent, privacy: .public)"
        )
    }

    /// What an `online` recording taps, decided at the moment it starts.
    ///
    /// M2 only has the manual case: if exactly one watchlist app is reading the
    /// microphone right now, that app is the meeting and the tap points at it — which
    /// also gives the folder its name and fills in `meta.trigger` even though the
    /// recording was started by hand. Anything else — nothing running, or two apps at
    /// once — is a system-wide tap and a folder called `…_Online`. M3 replaces the
    /// guess with actual detection and passes the app in.
    private func resolveOnlineTapTarget() -> TapTarget {
        let watchlist = settings.settings.watchlist
        #if DEBUG
        if let forced = forcedTapTargetBundleId {
            if let target = RunningMeetingApps.target(
                forBundleId: forced,
                in: RunningMeetingApps.current(),
                watchlist: watchlist
            ) {
                Log.detection.notice("tap target forced to \(forced, privacy: .public)")
                return target
            }
            Log.detection.error(
                "no audio process for the forced tap target \(forced, privacy: .public); tapping the whole system"
            )
            return .systemWide
        }
        #endif
        return RunningMeetingApps.currentTarget(watchlist: watchlist)
    }

    /// Cleans up after a `start` that timed out and then finished anyway.
    ///
    /// Abandoning the wait is not the same as forgetting: a start that comes back two
    /// minutes late has opened the hardware and written a WAV header, and both have to
    /// go — otherwise the microphone stays live behind a menu that says idle, and the
    /// folder keeps a zero-length `audio.wav` that `meta.json` never mentions.
    private nonisolated func abandon(
        start task: Task<AudioRecorderStart, any Error>,
        recorder: any AudioRecorder,
        folder: URL
    ) {
        Task.detached {
            _ = try? await task.value
            _ = try? await recorder.stop()
            let audio = folder.appendingPathComponent(WAVWriter.fileName)
            try? FileManager.default.removeItem(at: audio)
            Log.audio.notice("a late recorder start was stopped again and its audio file removed")
        }
    }

    // MARK: - Screenshots

    /// Starts capturing every display, and writes `meta.displays` when it knows what
    /// they are.
    ///
    /// Deliberately not awaited by the caller: opening the streams takes a fetch of
    /// `SCShareableContent` and a start per display, and a recording that waited for
    /// that would begin its audio a fraction of a second late for no benefit. Nothing
    /// in here can fail the recording — a missing Screen Recording permission, a
    /// display that refuses, a full disk all end as a log line and no images.
    private func startScreenshots(session: RecordingSession, started: Date) {
        var logsDecisions = false
        #if DEBUG
        logsDecisions = logsScreenshotDecisions
        #endif
        let configuration = ScreenshotCaptureConfiguration(
            settings: settings.settings,
            logsDecisions: logsDecisions
        )
        let isScreenLocked = appState.isScreenLocked
        screenshotStartTask = Task { [weak self] in
            guard let self else { return }
            let displays = await self.capturer.start(
                folder: session.folder,
                started: started,
                configuration: configuration,
                isScreenLocked: isScreenLocked
            )
            guard !displays.isEmpty else { return }
            // The stop awaits this task before it touches `meta.json`, so this write
            // can never land after the one that finishes the recording.
            try? session.update { $0.displays = displays }
        }
    }

    /// Stops the streams and answers with the number of images written, which is what
    /// `meta.screenshots` is.
    private func stopScreenshots() async -> Int {
        // A recording stopped within the second it started may still be opening its
        // streams; letting that finish is what keeps `meta.displays` honest.
        await screenshotStartTask?.value
        screenshotStartTask = nil
        return await capturer.stop()
    }

    /// The screen locked or unlocked. Audio does not care; screenshots do — two
    /// hundred images of the lock wallpaper are two hundred images of nothing.
    func setScreenLocked(_ isLocked: Bool) {
        capturer.setScreenLocked(isLocked)
    }

    // MARK: - Stopping

    /// Stops the recording and moves the folder through `transcribing` to `done`.
    ///
    /// In M0 there is nothing between those two states — no transcription exists yet —
    /// but `meta.json` is written at each step anyway, because that sequence is the
    /// contract a downstream tool and the crash recovery in M6 both read.
    /// - Parameter reason: what ended the recording. Written to `meta.json` as
    ///   `stopReason`, which is the only thing that tells a folder stopped by the user
    ///   apart from one auto-stopped by detection or cut short by the Mac sleeping.
    func stop(reason: MeetingStopReason = .manual) {
        // A stop pressed while the microphone is still being opened is not a mistake
        // and is not dropped: it is honoured the moment the recording exists.
        if isStarting {
            pendingStop = true
            pendingStopReason = reason
            Log.app.notice("stop requested while the recording was still starting")
            return
        }
        guard appState.phase.isRecording, !isStopping else {
            Log.app.debug("stop ignored: nothing is recording")
            return
        }
        pendingStopReason = reason
        isStopping = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isStopping = false }
            await self.finishRecording()
        }
    }

    /// Runs a stop that had to wait for the start to finish.
    private func honourPendingStop() {
        guard pendingStop else { return }
        pendingStop = false
        // If the start failed, there is nothing to stop and this is a no-op.
        Log.app.notice("honouring the stop that arrived during the start")
        stop(reason: pendingStopReason)
    }

    private func finishRecording() async {
        guard let session else {
            appState.phase = .idle
            return
        }
        self.session = nil
        let stopping = recorder
        self.recorder = nil

        let ended = Date()
        // Before the recorder's own stop, which may take seconds: the streams are
        // independent of the audio hardware and there is nothing to gain from a few
        // more frames of a meeting that is already over.
        let screenshots = await stopScreenshots()

        var outcome: AudioRecorderOutcome?
        var stopTimedOut = false
        if let stopping {
            switch await Deadline.run(recorderStopTimeout, operation: { try await stopping.stop() }) {
            case .finished(.success(let value)):
                outcome = value
            case .finished(.failure(let error)):
                Log.audio.error("recorder failed on stop: \(error.localizedDescription, privacy: .public)")
            case .timedOut(let task):
                stopTimedOut = true
                Log.audio.error("the recorder did not answer the stop within 15 s")
                // Let it finish on its own time: the file it is closing is the
                // recording, and the frames still in flight belong in it.
                Task.detached { _ = try? await task.value }
            }
        }

        if stopTimedOut {
            finishAfterStopTimeout(session: session, ended: ended, screenshots: screenshots)
            return
        }

        appState.phase = .processing(progress: nil, label: String(localized: "Verarbeitung"))

        let reason = pendingStopReason
        var handedOver = false
        do {
            try session.update { meta in
                meta.finishCapture(at: ended, reason: reason)
                meta.screenshots = screenshots
                if let outcome {
                    meta.channels = outcome.channels
                    meta.audio = outcome.audioFileName
                }
            }
            // recording → transcribing. The queue takes it from here and is what moves
            // it to `done`; a folder that says `transcribing` after a crash is exactly
            // what the next launch looks for.
            try session.transition(to: .transcribing)
            handedOver = true
        } catch {
            Log.storage.error("could not finish meta.json: \(error.localizedDescription, privacy: .public)")
            session.fail(reason: error.localizedDescription)
            appState.notice = error.localizedDescription
        }

        // Capture is over, so the claim on the folder goes: everything after this
        // point is the queue's, and the recovery scan leaves a folder past
        // `recording` alone whether it is locked or not.
        session.releaseLock()

        appState.lastMeetingURL = session.folder
        appState.lastMeetingState = session.meta.state
        Log.app.notice(
            """
            recording finished: \(session.folder.lastPathComponent, privacy: .public) \
            after \(Int(ended.timeIntervalSince(session.meta.started)), privacy: .public) s, \
            stopped by \(reason.rawValue, privacy: .public)
            """
        )
        recordingDidEnd()

        if handedOver, let transcription {
            // The queue owns the phase from here: it is what knows which step is
            // running and when the last folder is finished.
            transcription.enqueue(session.folder)
        } else {
            appState.phase = .idle
        }
    }

    /// Clears what belonged to the recording that just ended and tells detection.
    ///
    /// Detection has to hear about every ending, not only its own auto-stop: a user
    /// who stops a recording by hand in the middle of a call must not be offered the
    /// same call again ten seconds later.
    private func recordingDidEnd() {
        let bundleId = recordingBundleId
        recordingBundleId = nil
        pendingStopReason = .manual
        appState.recordingAppName = nil
        onRecordingEnded?(bundleId)
    }

    /// Finishes a folder whose recorder never answered the stop.
    ///
    /// The audio that reached the disk stays: `WAVWriter` writes as it goes, so
    /// whatever is in `audio.wav` is playable to within a fraction of a second of the
    /// stop, and the header is repairable in M6 if the writer never closed it. What
    /// the folder does *not* get is `done` — nothing here knows whether the recording
    /// is complete, and a folder that says `failed` with a reason is worth more than
    /// one that claims a clean ending it cannot vouch for.
    private func finishAfterStopTimeout(session: RecordingSession, ended: Date, screenshots: Int) {
        let audio = session.folder.appendingPathComponent(WAVWriter.fileName)
        let hasAudio = FileManager.default.fileExists(atPath: audio.stenoPath)
        let mode = session.meta.mode
        let stopReason = pendingStopReason
        try? session.update { meta in
            meta.finishCapture(at: ended, reason: stopReason)
            meta.screenshots = screenshots
            meta.channels = mode.channels
            meta.audio = hasAudio ? WAVWriter.fileName : nil
        }
        let reason = RecorderTimeout.stop.localizedDescription
        session.fail(reason: reason)
        session.releaseLock()
        appState.lastMeetingURL = session.folder
        appState.lastMeetingState = session.meta.state
        appState.notice = reason
        appState.phase = .idle
        notifyFailure(reason: reason, folder: session.folder)
        recordingDidEnd()
    }

    // MARK: - Quitting

    /// Releases the audio hardware before the process exits.
    ///
    /// Quitting with a process tap still open leaves it behind in `coreaudiod`, and a
    /// leaked tap is not a tidiness problem: the daemon gets into a state where the
    /// *next* `AudioDeviceStart` blocks for ever, and every recording after it fails
    /// with "the audio system is not answering" until the Mac is restarted. So the
    /// recorder is given a few seconds to hand the hardware back, on the way out.
    ///
    /// Blocking the main thread is deliberate and is the only thing that works here:
    /// `applicationWillTerminate` is the last moment there is, and an `await` would
    /// return to a run loop that is never going to run again. The recorder is an actor
    /// of its own, so its work proceeds on another thread while this one waits.
    ///
    /// `meta.json` is left saying `recording`. That is not an oversight: the folder is
    /// exactly what a crash would have left, and M6's recovery pass is what finishes
    /// it — claiming a clean ending for a recording that was cut off mid-sentence
    /// would be worse than saying plainly that it was.
    func prepareForTermination() {
        // First and synchronously: `screens.jsonl` must be flushed and closed even
        // when there is no recorder to wait for, because a folder whose last index
        // line is half-written is worse than one line short.
        screenshotStartTask?.cancel()
        screenshotStartTask = nil
        capturer.prepareForTermination()

        guard let stopping = recorder else { return }
        recorder = nil
        Log.audio.notice("quitting while recording; releasing the audio hardware")
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await stopping.stop()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            Log.audio.error("the recorder did not release the hardware before the app quit")
        }
    }

    // MARK: - Interruptions

    /// The recording ended without anyone asking: the device went away, or the file
    /// could not be written.
    ///
    /// The folder is finished the way a crash-recovery pass would want to find it:
    /// `ended` and `duration` set from the moment the interruption arrived, the audio
    /// that was captured named in `meta.audio`, and `state: failed` with a reason.
    /// Deliberately not `transcribing`: a partial recording is worth keeping and
    /// transcribing, but M6 is what decides that, from a folder that says plainly what
    /// happened rather than one that pretends the recording ran to the end.
    func handleInterruption(_ reason: AudioInterruptionReason) {
        guard let session, appState.phase.isRecording else {
            Log.audio.debug("interruption arrived after the recording had already ended")
            return
        }
        self.session = nil
        let stopping = recorder
        self.recorder = nil

        Log.audio.error("recording interrupted: \(reason.localizedReason, privacy: .public)")

        let ended = Date()
        let deadline = recorderStopTimeout
        Task { [weak self] in
            // The recorder has already closed its file; this is what releases the
            // hardware and hands back what was written. Under the same deadline as an
            // ordinary stop: a folder that says `failed` is the whole point of this
            // path, and it must not be held up by hardware that will not let go.
            var outcome: AudioRecorderOutcome?
            if let stopping {
                outcome = await Deadline.run(deadline) { try await stopping.stop() }.value
            }
            guard let self else { return }
            let screenshots = await self.stopScreenshots()
            self.finishInterrupted(
                session: session,
                reason: reason,
                ended: ended,
                outcome: outcome,
                screenshots: screenshots
            )
        }
    }

    private func finishInterrupted(
        session: RecordingSession,
        reason: AudioInterruptionReason,
        ended: Date,
        outcome: AudioRecorderOutcome?,
        screenshots: Int
    ) {
        try? session.update { meta in
            meta.finishCapture(at: ended, reason: reason.stopReason)
            meta.screenshots = screenshots
            if let outcome {
                meta.channels = outcome.channels
                meta.audio = outcome.audioFileName
            }
        }
        session.fail(reason: reason.localizedReason)
        session.releaseLock()

        appState.lastMeetingURL = session.folder
        appState.lastMeetingState = session.meta.state
        appState.notice = reason.localizedReason
        appState.phase = .idle
        notifyFailure(reason: reason.localizedReason, folder: session.folder)
        recordingDidEnd()
    }

    // MARK: - Notifications

    /// Tells the user that a recording ended badly.
    ///
    /// The plan's addition to specification §5: a failure is worth a banner because
    /// the recording is gone and the meeting is still running, so the user can start
    /// it again. The `done` notification is the transcription queue's. Silent unless
    /// the user has both switched notifications on and granted them.
    private func notifyFailure(reason: String, folder: URL?) {
        let isEnabled = settings.settings.notificationsEnabled
        Task {
            await Notifications.shared.post(
                title: String(localized: "Aufnahme fehlgeschlagen"),
                body: reason,
                folder: folder,
                isEnabled: isEnabled
            )
        }
    }

    // MARK: - Disk space

    /// Puts a note in the menu when space is short, and shows one alert per launch.
    private func warnIfDiskSpaceIsLow(at root: URL, bytes: Int64?) {
        guard let bytes, bytes < DiskSpace.warnBelow else { return }
        let message = String(
            format: String(localized: "Nur noch %@ frei. Eine Stunde Aufnahme braucht rund 1 GB."),
            DiskSpace.formatted(bytes)
        )
        appState.notice = message
        Log.storage.notice("low disk space: \(DiskSpace.formatted(bytes), privacy: .public)")

        guard !hasWarnedAboutDiskSpace else { return }
        hasWarnedAboutDiskSpace = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Wenig Speicherplatz")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Weiter"))
        NSApp.activate()
        alert.runModal()
    }
}
