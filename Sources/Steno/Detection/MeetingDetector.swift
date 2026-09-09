import CoreAudio
import Foundation
import StenoCore

/// One meeting, as detection sees it.
struct DetectedMeeting: Sendable, Equatable {
    /// The watchlist entry. This, not the individual process, is "the meeting app":
    /// Chrome and its four helpers are one meeting.
    var app: WatchedApp
    /// Every process belonging to that entry, whether or not it is the one reading
    /// input — the tap needs all of them, and so does the window-title search.
    var pids: [pid_t]

    var bundleId: String { app.bundleId }
    var name: String { app.name }

    /// What an `online` recording of this meeting should tap.
    var tapTarget: TapTarget {
        pids.isEmpty ? .systemWide : .process(pids: pids, bundleId: app.bundleId, name: app.name)
    }

    /// The trigger `meta.json` records for a recording detection started.
    var trigger: MeetingTrigger {
        .auto(bundleId: app.bundleId, name: app.name)
    }
}

/// Specification §2: which watchlist app is in a meeting, and when it stops being one.
///
/// The detector is glue and nothing else. It asks a `ProcessAudioSource` which
/// processes are reading the microphone, groups them onto watchlist entries by bundle
/// prefix, and hands the resulting set to `StenoCore.MeetingDetectorLogic` — where the
/// five-second debounce, the thirty-second auto-stop silence, and the sixty-second
/// "ask once per meeting" hysteresis actually live, tested against a clock a test
/// owns. What is left here is Core Audio, a timer, and two closures.
///
/// **Detection keeps running while a recording is running.** Specification §1 says new
/// triggers are ignored, and they are — by the coordinator, which refuses a start. The
/// detector must not stop watching, because auto-stop is the same machinery: the app
/// that is being recorded going quiet is what ends the recording.
@MainActor
final class MeetingDetector {
    /// How often the state machine is advanced.
    ///
    /// A listener says *that* something changed; only a clock can say that five
    /// seconds of microphone use have passed with nothing changing at all. One second
    /// is fine for a five-second debounce and costs a dictionary walk over seven
    /// watchlist entries.
    static let tickInterval: TimeInterval = 1
    /// How often the whole process list is re-read when listeners are unavailable.
    /// Specification §2's permitted first cut.
    static let pollInterval: TimeInterval = 2
    /// How often the list is re-read even when listeners work, as a consistency check.
    /// A missed notification would otherwise leave detection blind until the next one.
    static let resyncInterval: TimeInterval = 30

    private let settings: SettingsStore
    private var source: any ProcessAudioSource
    private var logic: MeetingDetectorLogic

    /// Called when a watchlist app has been reading the microphone long enough.
    /// Ignoring it while a recording runs is the caller's job (specification §1).
    var onMeetingStarted: ((DetectedMeeting) -> Void)?
    /// Called when the app of a detected meeting has been quiet long enough. This is
    /// auto-stop.
    var onMeetingEnded: ((WatchedApp) -> Void)?

    private var ticker: Timer?
    private var processes: [AudioProcessDescriptor] = []
    private var lastSnapshotAt: TimeInterval = 0
    private(set) var isRunning = false

    init(settings: SettingsStore, source: (any ProcessAudioSource)? = nil) {
        self.settings = settings
        self.source = source ?? CoreAudioProcessSource()
        self.logic = MeetingDetectorLogic(
            watchlist: settings.settings.watchlist,
            timing: MeetingDetectorTiming(autoStop: settings.settings.autoStopDelay)
        )
    }

    // MARK: - The clock

    /// Monotonic seconds. `systemUptime` is `mach_absolute_time` in disguise: it never
    /// goes backwards when the wall clock is adjusted, and it does not run while the
    /// Mac is asleep — which is what stops a machine that slept through lunch from
    /// firing an auto-stop the moment it wakes.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Running

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logic.reset()
        syncSettings()

        source.start { [weak self] in
            self?.handleSourceChange()
        }
        refreshSnapshot()

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes, so detection keeps running while a menu is open — a user who
        // holds the menu bar down for twenty seconds must not miss their meeting.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        Log.detection.notice(
            """
            detection started: \(self.settings.settings.watchlist.count, privacy: .public) watched apps, \
            \(self.source.isEventDriven ? "listeners" : "polling", privacy: .public), \
            auto-stop after \(Int(self.settings.settings.autoStopDelay), privacy: .public) s
            """
        )
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        ticker?.invalidate()
        ticker = nil
        source.stop()
        logic.reset()
        Log.detection.notice("detection stopped")
    }

    /// Forgets that a meeting was offered and is running, without re-arming the offer.
    ///
    /// Called when a recording ends for a reason detection knows nothing about — the
    /// user pressed stop, the Mac went to sleep. The call itself may well still be
    /// running, and offering to record it again ten seconds later would be exactly the
    /// nagging specification §2's hysteresis exists to prevent.
    func forgetMeeting(_ bundleId: String) {
        logic.forgetMeeting(bundleId)
    }

    /// Whether this app is in a meeting as far as detection is concerned.
    func isInMeeting(_ bundleId: String) -> Bool {
        logic.isInMeeting(bundleId)
    }

    /// Every process of a watchlist app right now, for a tap target that was resolved
    /// at trigger time and may be stale by the time recording starts.
    func currentProcesses(of app: WatchedApp) -> [pid_t] {
        RunningMeetingApps.processes(of: app, in: source.snapshot()).map(\.pid)
    }

    // MARK: - The loop

    private func handleSourceChange() {
        guard isRunning else { return }
        refreshSnapshot()
        evaluate()
    }

    private func tick() {
        guard isRunning else { return }
        syncSettings()
        let interval = source.isEventDriven ? Self.resyncInterval : Self.pollInterval
        if now - lastSnapshotAt >= interval { refreshSnapshot() }
        evaluate()
    }

    private func refreshSnapshot() {
        processes = source.snapshot()
        lastSnapshotAt = now
    }

    /// Keeps the state machine in step with the settings window.
    ///
    /// Both values are edited while detection runs, and both change what the machine
    /// does on its very next tick — a watchlist entry removed mid-call must stop being
    /// watched, and a shortened auto-stop delay must apply to the recording that is
    /// already running.
    private func syncSettings() {
        let watchlist = settings.settings.watchlist
        if logic.watchlist != watchlist { logic.watchlist = watchlist }
        let autoStop = settings.settings.autoStopDelay
        if logic.timing.autoStop != autoStop { logic.timing.autoStop = autoStop }
    }

    private func evaluate() {
        let matches = RunningMeetingApps.matches(in: processes, watchlist: logic.watchlist)
        let active = Set(matches.map(\.app.bundleId))
        for event in logic.update(activeBundleIds: active, now: now) {
            deliver(event)
        }
    }

    private func deliver(_ event: MeetingDetectorEvent) {
        switch event {
        case .meetingStarted(let app):
            let pids = RunningMeetingApps.processes(of: app, in: processes).map(\.pid)
            Log.detection.notice(
                """
                meeting detected: \(app.name, privacy: .public) (\(app.bundleId, privacy: .public)), \
                \(pids.count, privacy: .public) processes
                """
            )
            onMeetingStarted?(DetectedMeeting(app: app, pids: pids))
        case .meetingEnded(let app):
            Log.detection.notice(
                "meeting ended: \(app.name, privacy: .public) has not read the microphone for \(Int(self.logic.timing.autoStop), privacy: .public) s"
            )
            onMeetingEnded?(app)
        }
    }

    // MARK: - Test and simulation hooks

    #if DEBUG
    /// Swaps in a process list a debug run writes by hand. Only possible while
    /// detection is stopped, and only `--simulate-detection` does it.
    func useSource(_ source: any ProcessAudioSource) {
        guard !isRunning else { return }
        self.source = source
    }

    /// Shortens the debounce so a simulated meeting does not take five seconds to
    /// notice. Nothing but `--simulate-detection` and the tests call this.
    func setTiming(_ timing: MeetingDetectorTiming) {
        logic.timing = timing
    }

    /// Advances the machine immediately, rather than waiting for the next tick.
    func evaluateNow() {
        refreshSnapshot()
        evaluate()
    }
    #endif
}
