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
    private let recorder: any AudioRecorder

    /// Set while a start or a stop is in flight, so a second hotkey press during the
    /// hardware handshake does not open a second recording.
    private var isTransitioning = false
    private var session: RecordingSession?
    /// The low-space alert is shown once per launch, not once per recording.
    private var hasWarnedAboutDiskSpace = false

    init(
        appState: AppState,
        settings: SettingsStore,
        store: RecordingStore,
        recorder: any AudioRecorder
    ) {
        self.appState = appState
        self.settings = settings
        self.store = store
        self.recorder = recorder
    }

    // MARK: - May we?

    /// The first thing standing in the way of a recording, or `nil` when nothing is.
    ///
    /// The order is deliberate: state first, because "already recording" is not a
    /// problem the user has to fix; then permissions, which is what §8 asks the menu to
    /// name; then the disk.
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
            return
        }

        isTransitioning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }
            await self.beginRecording(mode: mode, trigger: trigger, appName: appName, title: title)
        }
    }

    private func beginRecording(
        mode: MeetingMode,
        trigger: MeetingTrigger,
        appName: String?,
        title: String?
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
            os: AppVersion.osVersion
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

        do {
            let opened = try await recorder.start(
                AudioRecorderConfiguration(
                    mode: mode,
                    folder: folder,
                    inputDeviceUID: settings.settings.onsiteInputDeviceUID,
                    started: started
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
        appState.phase = .recording(mode: mode, started: started)
        appState.notice = nil
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
        guard appState.phase.isRecording, !isTransitioning else {
            Log.app.debug("stop ignored: nothing is recording")
            return
        }
        isTransitioning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }
            await self.finishRecording()
        }
    }

    private func finishRecording() async {
        guard let session else {
            appState.phase = .idle
            return
        }
        self.session = nil

        let ended = Date()
        var outcome: AudioRecorderOutcome?
        do {
            outcome = try await recorder.stop()
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
