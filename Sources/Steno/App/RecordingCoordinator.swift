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
/// arrives through `AudioRecorder`, which is a `NullRecorder` in M0 and a real one in
/// M1 and M2 — so the flow below (folder, `meta.json` at every state change, disk
/// check, `mm:ss`, hotkeys) is finished and exercised now rather than being written
/// twice.
@MainActor
final class RecordingCoordinator {
    private let appState: AppState
    private let settings: SettingsStore
    private let store: RecordingStore
    private(set) var recorderFactory: any RecorderFactory

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

    private var session: RecordingSession?
    /// The recorder of the running recording. Opened per recording, because holding a
    /// microphone between meetings is both wasteful and visible in the menu bar.
    private var recorder: (any AudioRecorder)?
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
        if let missing = appState.permissions.firstMissing(for: requirement) {
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
    /// `appName` and `title` come from detection in M3; in M0 both are `nil` for a
    /// manual start, which is what makes the folder `…_Meeting` for `online` and
    /// `…_Vorort` for `onsite`.
    func start(
        mode: MeetingMode,
        trigger: MeetingTrigger,
        appName: String? = nil,
        title: String? = nil
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

        let folder = store.meetingFolderURL(
            in: root,
            started: started,
            mode: mode,
            appName: appName,
            title: settings.settings.includeTitleInFolderName ? title : nil
        )

        // `meta.json` is written before the first audio frame, so a crash a second
        // later still leaves a folder that says what it was.
        let meta = MeetingMeta(
            mode: mode,
            started: started,
            trigger: trigger,
            input: AudioInputInfo(
                device: AudioInputDevices.displayName(forUID: settings.settings.onsiteInputDeviceUID)
            ),
            app: AppVersion.marketing,
            state: .recording,
            title: title,
            appBuild: AppVersion.build,
            os: AppVersion.osVersion,
            // Written from the first second, so a recording interrupted before it
            // finished still carries the number the user gave into M5's diarizer.
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

        do {
            let opened = try await newRecorder.start(
                AudioRecorderConfiguration(
                    mode: mode,
                    folder: folder,
                    inputDeviceUID: settings.settings.onsiteInputDeviceUID,
                    started: started,
                    onInterruption: onInterruption
                )
            )
            try? newSession.update { meta in
                meta.input = AudioInputInfo(
                    device: opened.deviceName,
                    microphoneMode: opened.microphoneMode
                )
            }
        } catch {
            Log.audio.error("recorder refused to start: \(error.localizedDescription, privacy: .public)")
            newSession.fail(reason: error.localizedDescription)
            appState.notice = error.localizedDescription
            return
        }

        session = newSession
        recorder = newRecorder
        appState.phase = .recording(mode: mode, started: started)
        // Nothing needs saying about a recording that started — except the
        // microphone-mode hint, which stays up for as long as it runs.
        appState.notice = microphoneHint
        Log.app.notice(
            "recording started: \(mode.rawValue, privacy: .public) in \(folder.lastPathComponent, privacy: .public)"
        )
    }

    // MARK: - Stopping

    /// Stops the recording and moves the folder through `transcribing` to `done`.
    ///
    /// In M0 there is nothing between those two states — no transcription exists yet —
    /// but `meta.json` is written at each step anyway, because that sequence is the
    /// contract a downstream tool and the crash recovery in M6 both read.
    func stop() {
        // A stop pressed while the microphone is still being opened is not a mistake
        // and is not dropped: it is honoured the moment the recording exists.
        if isStarting {
            pendingStop = true
            Log.app.notice("stop requested while the recording was still starting")
            return
        }
        guard appState.phase.isRecording, !isStopping else {
            Log.app.debug("stop ignored: nothing is recording")
            return
        }
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
        stop()
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
        var outcome: AudioRecorderOutcome?
        do {
            outcome = try await stopping?.stop()
        } catch {
            Log.audio.error("recorder failed on stop: \(error.localizedDescription, privacy: .public)")
        }

        appState.phase = .processing(progress: nil, label: String(localized: "Verarbeitung"))

        do {
            try session.update { meta in
                meta.finishCapture(at: ended)
                if let outcome {
                    meta.channels = outcome.channels
                    meta.audio = outcome.audioFileName
                }
            }
            // recording → transcribing: what M5 will actually spend time in.
            try session.transition(to: .transcribing)
            // transcribing → done: immediate until M5 puts a transcript in between.
            try session.transition(to: .done)
        } catch {
            Log.storage.error("could not finish meta.json: \(error.localizedDescription, privacy: .public)")
            session.fail(reason: error.localizedDescription)
            appState.notice = error.localizedDescription
        }

        appState.lastMeetingURL = session.folder
        appState.phase = .idle
        Log.app.notice(
            """
            recording finished: \(session.folder.lastPathComponent, privacy: .public) \
            after \(Int(ended.timeIntervalSince(session.meta.started)), privacy: .public) s
            """
        )
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
        Task { [weak self] in
            // The recorder has already closed its file; this is what releases the
            // hardware and hands back what was written.
            let outcome = try? await stopping?.stop()
            guard let self else { return }
            self.finishInterrupted(
                session: session,
                reason: reason,
                ended: ended,
                outcome: outcome
            )
        }
    }

    private func finishInterrupted(
        session: RecordingSession,
        reason: AudioInterruptionReason,
        ended: Date,
        outcome: AudioRecorderOutcome?
    ) {
        try? session.update { meta in
            meta.finishCapture(at: ended)
            if let outcome {
                meta.channels = outcome.channels
                meta.audio = outcome.audioFileName
            }
        }
        session.fail(reason: reason.localizedReason)

        appState.lastMeetingURL = session.folder
        appState.notice = reason.localizedReason
        appState.phase = .idle
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
