import Foundation
import Observation
import StenoCore

/// The objects that make up one running Steno, wired together once.
///
/// A menu-bar app has no window hierarchy to hang dependencies off: the status item,
/// the settings window, the onboarding window, the hotkey handler, and the app
/// delegate all need the same five objects, and none of them owns the others. So they
/// are constructed here and reached through `shared`.
///
/// Everything in it is `@MainActor`, which is what makes that safe: there is one
/// instance, on one actor, for the life of the process.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: SettingsStore
    let appState: AppState
    let store: RecordingStore
    let models: ModelManager
    /// Specification §5, serialized: one meeting transcribed at a time.
    let transcription: TranscriptionQueue
    let permissions: PermissionMonitor
    let inputDevices: AudioInputDeviceList
    let coordinator: RecordingCoordinator
    let hotKeys: HotKeys
    /// Specification §2: who is reading the microphone, and what follows from it.
    let detector: MeetingDetector
    /// The trigger-to-recording path — rules, the popup, auto-stop, sleep.
    let detectionController: MeetingDetectionController
    /// never / ask / always, from the rules and the meeting's title.
    let ruleEngine: RuleEngine
    /// Sparkle, or a stand-in that reports itself unconfigured when the bundle has no
    /// usable public key.
    let updater: UpdaterController
    /// Sleep and the lock screen.
    private(set) var sleepLock: SleepLockObserver?

    /// What the launch-time recovery scan found, for the menu and for `--recover-and-quit`.
    private(set) var lastRecoveryReport: RecoveryScanner.Report?

    /// Where the coordinator gets a recorder from. The default gives `onsite`
    /// `MicRecorder` (§3b) and `online` `ProcessTapRecorder` (§3a); the tests and
    /// `--simulate-null-recording` substitute one that touches no hardware.
    let recorderFactory: any RecorderFactory

    init(
        settings: SettingsStore? = nil,
        recorderFactory: (any RecorderFactory)? = nil
    ) {
        let settings = settings ?? Self.makeSettingsStore()
        self.settings = settings
        self.appState = AppState()
        self.store = RecordingStore()
        self.models = ModelManager(asrVersion: settings.settings.asrVersion)
        self.inputDevices = AudioInputDeviceList()
        self.recorderFactory = recorderFactory ?? DefaultRecorderFactory()

        let models = self.models
        self.permissions = PermissionMonitor(modelsInstalled: { models.isInstalled })

        let coordinator = RecordingCoordinator(
            appState: appState,
            settings: settings,
            store: store,
            recorderFactory: self.recorderFactory
        )
        self.coordinator = coordinator

        let transcription = TranscriptionQueue(
            appState: appState,
            settings: settings,
            models: self.models,
            store: TranscriptionQueueStore(defaults: settings.defaults)
        )
        self.transcription = transcription
        // A finished recording is handed over rather than declared done: the queue is
        // what writes the transcript and moves `meta.json` to `done`.
        coordinator.transcription = transcription
        self.hotKeys = HotKeys()
        self.updater = UpdaterController(settings: settings)

        let detector = MeetingDetector(settings: settings)
        self.detector = detector
        // The title source asks the detector for a fresh process list between
        // attempts: a browser opens a new helper for the call after the trigger has
        // already fired, and the window with the meeting's name in it belongs to that
        // one.
        let titleSource = SystemMeetingTitleSource(
            settings: settings,
            refreshPIDs: { [weak detector] meeting in
                detector?.currentProcesses(of: meeting.app) ?? meeting.pids
            }
        )
        let ruleEngine = RuleEngine(settings: settings, titleSource: titleSource)
        self.ruleEngine = ruleEngine
        self.detectionController = MeetingDetectionController(
            settings: settings,
            appState: appState,
            coordinator: coordinator,
            detector: detector,
            ruleEngine: ruleEngine
        )
    }

    // MARK: - Launch

    /// Everything that has to happen once, at launch.
    ///
    /// - Parameter detection: whether specification §2's detection is switched on. The
    ///   only caller that says `false` is a debug run that drives detection itself, so
    ///   that a simulation is not interrupted by a real meeting starting on this Mac.
    func start(detection: Bool = true) {
        settings.syncLaunchAtLogin()
        models.asrVersion = settings.settings.asrVersion

        _ = store.ensureRootExists(settings.rootFolderURL)

        // Before anything else looks at the root, and before detection can start a
        // recording into it: specification §6 and §10's M6 — a folder still saying
        // `recording` or `transcribing` was interrupted, and this is the launch that
        // finishes it. The queue's own list of folders comes second, so that a folder
        // the scan has just repaired and queued is not queued twice.
        runRecoveryScan()
        transcription.resumePersisted()
        refreshLastMeeting()

        permissions.observeActivation()
        inputDevices.startObserving()

        hotKeys.register { [weak self] action in
            self?.handle(action)
        }

        // The delegate and the "Im Finder zeigen" action, neither of which prompts.
        // Authorization is asked for in the onboarding window and the settings toggle,
        // and nowhere else.
        Notifications.shared.prepare()

        let sleepLock = SleepLockObserver(
            onWillSleep: { [weak self] in
                self?.detectionController.handleWillSleep()
            },
            onLockChange: { [weak self] isLocked in
                self?.appState.isScreenLocked = isLocked
                // The recording carries on; only the screenshots pause (§4, plan
                // addition). Told rather than observed, so the capturer has no reason
                // to know about `AppState` at all.
                self?.coordinator.setScreenLocked(isLocked)
            }
        )
        sleepLock.start()
        self.sleepLock = sleepLock

        // After the recovery scan and the queue, and deliberately last of the
        // background jobs: an update check must never be what a launch waits on.
        updater.start()

        if detection { detectionController.start() }

        Task { [weak self] in
            guard let self else { return }
            await self.permissions.refresh()
            self.appState.permissions = self.permissions.snapshot
            self.observePermissions()
        }
    }

    /// Undone on quit, so the hotkeys and the ticker do not outlive the app.
    func stop() {
        // First, because a process tap left open in `coreaudiod` wedges the next
        // recording — and every one after it.
        coordinator.prepareForTermination()
        transcription.prepareForTermination()
        detectionController.stop()
        sleepLock?.stop()
        sleepLock = nil
        hotKeys.unregister()
        permissions.stopPeriodicRefresh()
        appState.stopTicker()
    }

    func handle(_ action: HotKeys.Action) {
        switch action {
        case .startOnline: coordinator.startOnline()
        case .startOnsite: coordinator.startOnsite()
        case .stop: coordinator.stop()
        }
    }

    /// Mirrors the permission snapshot into `AppState`, which is what the menu reads.
    ///
    /// `withObservationTracking` fires once per change, so it re-arms itself. Cheaper
    /// and more direct than a Combine pipeline for one value.
    private func observePermissions() {
        withObservationTracking {
            _ = permissions.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState.permissions = self.permissions.snapshot
                self.observePermissions()
            }
        }
    }

    /// Finishes what the last run did not, once, at launch.
    ///
    /// The result reaches the menu as a notice rather than a dialog: a meeting being
    /// picked up again is worth saying and not worth interrupting anyone for.
    private func runRecoveryScan() {
        let scanner = RecoveryScanner(
            store: store,
            queueStore: TranscriptionQueueStore(defaults: settings.defaults)
        )
        let report = scanner.scan(root: settings.rootFolderURL) { [weak self] folder in
            self?.transcription.enqueue(folder)
        }
        lastRecoveryReport = report
        if let notice = report.localizedNotice { appState.notice = notice }
    }

    /// The settings store, pointed at whichever `UserDefaults` this process should use.
    ///
    /// In a release build there is only one answer. In a debug build `--defaults-suite`
    /// gives a test run its own settings and its own transcription queue, so that it
    /// cannot disturb — or be disturbed by — the copy of Steno somebody may have running
    /// at the same time under the same bundle identifier.
    private static func makeSettingsStore() -> SettingsStore {
        #if DEBUG
        let arguments = DebugLaunchArguments.current
        let defaults = arguments.defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) }
        let store = SettingsStore(defaults: defaults ?? .standard)
        if let suite = arguments.defaultsSuiteName {
            Log.app.notice("debug: settings and queue in the \(suite, privacy: .public) defaults suite")
        }
        if let root = arguments.rootFolderOverride {
            store.rootFolderOverride = root
            Log.app.notice("debug: recording root overridden to \(root.stenoPath, privacy: .public)")
        }
        return store
        #else
        return SettingsStore()
        #endif
    }

    // MARK: - Root folder

    /// Points the recording root somewhere else and brings everything in line.
    func changeRootFolder(to url: URL) {
        settings.setRootFolder(url)
        _ = store.ensureRootExists(url)
        refreshLastMeeting()
    }

    /// Re-reads which meeting is the newest. Called after a recording finishes and
    /// when the menu opens, because the user may have moved folders around.
    func refreshLastMeeting() {
        let folder = store.lastMeetingURL(in: settings.rootFolderURL)
        appState.lastMeetingURL = folder
        appState.lastMeetingState = folder.flatMap(store.state(of:))
    }
}
