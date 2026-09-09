import Foundation

/// The three timings meeting detection runs on. Specification §2.
///
/// They are one value rather than three constants because the state machine below is
/// tested by driving a clock forward by hand, and a test that has to wait five real
/// seconds for a debounce is a test nobody runs twice.
public struct MeetingDetectorTiming: Sendable, Equatable {
    /// How long a watched app has to read the microphone before it counts as a
    /// meeting. Specification §2: "bleibt ≥ 5 s true".
    public var trigger: TimeInterval
    /// How long no watched process may read the microphone before a running `online`
    /// recording stops itself. Specification §2: "≥ 30 s". The user can change it.
    public var autoStop: TimeInterval
    /// How long an app has to stay quiet before Steno offers to record it again.
    /// Specification §2: "Pro Meeting nur einmal fragen … bis `IsRunningInput`
    /// mindestens 60 s false war".
    public var rearm: TimeInterval

    public init(trigger: TimeInterval = 5, autoStop: TimeInterval = 30, rearm: TimeInterval = 60) {
        self.trigger = trigger
        self.autoStop = autoStop
        self.rearm = rearm
    }

    public static let `default` = MeetingDetectorTiming()
}

/// What the state machine has decided about one watched app.
public enum MeetingDetectorEvent: Sendable, Equatable {
    /// The app has been reading the microphone for `timing.trigger` seconds and has
    /// not been asked about recently. The suggestion, the rules, and an `always` start
    /// all hang off this.
    case meetingStarted(app: WatchedApp)
    /// No process of an app that had started a meeting has read the microphone for
    /// `timing.autoStop` seconds. This is auto-stop.
    case meetingEnded(app: WatchedApp)

    public var app: WatchedApp {
        switch self {
        case .meetingStarted(let app), .meetingEnded(let app): return app
        }
    }
}

/// Meeting detection, as a pure function of "which watched apps are reading the
/// microphone right now" and a clock.
///
/// Everything that makes detection tricky — the five-second debounce, the thirty-second
/// silence before auto-stop, the sixty-second hysteresis that stops Steno asking twice
/// about the same meeting — is timing, and timing is exactly what is miserable to test
/// against real hardware. So all of it lives here, with no Core Audio, no listeners,
/// and no `Date()`: `update(activeBundleIds:now:)` is called with a monotonic timestamp
/// and returns what happened. `MeetingDetector` in the app is then only the glue that
/// asks the HAL what is active and hands the answers on.
///
/// Time is a `TimeInterval` from any monotonic source — `ContinuousClock` in the app,
/// a plain counter in the tests. It must never go backwards; a wall clock adjusted by
/// NTP would make a debounce fire early.
public struct MeetingDetectorLogic: Sendable {
    /// One watched app's history, as far as detection cares about it.
    struct EntryState: Sendable, Equatable {
        /// Start of the current uninterrupted run of microphone use, or `nil` while
        /// the app is quiet.
        var activeSince: TimeInterval?
        /// Start of the current uninterrupted silence, or `nil` while it is active.
        var inactiveSince: TimeInterval?
        /// Whether a `meetingStarted` has been emitted that no `meetingEnded` has
        /// answered yet. What makes auto-stop fire for the app that is being recorded
        /// and for no other.
        var isInMeeting = false
        /// Whether this app has already been offered once. Cleared after `rearm`
        /// seconds of silence, and the whole of "ask once per meeting".
        var wasOffered = false
    }

    public var timing: MeetingDetectorTiming
    /// The apps being watched. Changing it drops the state of everything removed, so
    /// editing the watchlist mid-meeting cannot leave a ghost entry behind that fires
    /// an auto-stop later.
    public var watchlist: [WatchedApp] {
        didSet {
            let known = Set(watchlist.map(\.bundleId))
            states = states.filter { known.contains($0.key) }
        }
    }

    private var states: [String: EntryState] = [:]

    public init(watchlist: [WatchedApp], timing: MeetingDetectorTiming = .default) {
        self.watchlist = watchlist
        self.timing = timing
    }

    // MARK: - The state machine

    /// Advances the machine to `now` and reports what changed.
    ///
    /// - Parameters:
    ///   - activeBundleIds: watchlist bundle identifiers with at least one process
    ///     reading the microphone. Which processes those are is the app's business;
    ///     an app with three helpers all reading input is one entry here.
    ///   - now: seconds from a monotonic clock. Must not go backwards.
    /// - Returns: the events this step produced, in watchlist order.
    public mutating func update(
        activeBundleIds: Set<String>,
        now: TimeInterval
    ) -> [MeetingDetectorEvent] {
        var events: [MeetingDetectorEvent] = []
        for app in watchlist {
            var state = states[app.bundleId] ?? EntryState()
            if activeBundleIds.contains(app.bundleId) {
                advanceActive(&state, app: app, now: now, into: &events)
            } else {
                advanceInactive(&state, app: app, now: now, into: &events)
            }
            states[app.bundleId] = state
        }
        return events
    }

    private func advanceActive(
        _ state: inout EntryState,
        app: WatchedApp,
        now: TimeInterval,
        into events: inout [MeetingDetectorEvent]
    ) {
        if state.activeSince == nil {
            state.activeSince = now
            state.inactiveSince = nil
        }
        guard let since = state.activeSince, !state.wasOffered else { return }
        // `>=`, not `>`: five seconds of microphone use is the trigger, not five
        // seconds and one poll interval.
        guard now - since >= timing.trigger else { return }
        state.wasOffered = true
        state.isInMeeting = true
        events.append(.meetingStarted(app: app))
    }

    private func advanceInactive(
        _ state: inout EntryState,
        app: WatchedApp,
        now: TimeInterval,
        into events: inout [MeetingDetectorEvent]
    ) {
        if state.inactiveSince == nil {
            state.inactiveSince = now
            state.activeSince = nil
        }
        guard let since = state.inactiveSince else { return }
        let silence = now - since

        // Auto-stop first: an app that has been quiet long enough ends its meeting
        // even if the re-arm window has not passed yet, because those two answer
        // different questions — one ends a recording, the other permits a new offer.
        if state.isInMeeting, silence >= timing.autoStop {
            state.isInMeeting = false
            events.append(.meetingEnded(app: app))
        }
        if state.wasOffered, silence >= timing.rearm {
            state.wasOffered = false
        }
    }

    // MARK: - Reading the machine

    /// Whether this app is considered to be in a meeting right now — i.e. a start was
    /// reported and no end has followed. Used by the app to decide whether an
    /// auto-stop belongs to the recording that is running.
    public func isInMeeting(_ bundleId: String) -> Bool {
        states[bundleId]?.isInMeeting ?? false
    }

    /// Whether this app has been offered and may not be offered again yet.
    public func wasOffered(_ bundleId: String) -> Bool {
        states[bundleId]?.wasOffered ?? false
    }

    /// Forgets that an app was ever offered or in a meeting, without touching its
    /// activity history.
    ///
    /// The one caller is a recording that ended for some other reason — the user
    /// pressed stop, the Mac went to sleep. The meeting may well still be running, and
    /// the app must not immediately be offered again just because it is still reading
    /// the microphone; but the offer that was made is over, so the auto-stop that would
    /// have followed it has nothing left to stop.
    public mutating func forgetMeeting(_ bundleId: String) {
        states[bundleId]?.isInMeeting = false
    }

    /// Drops everything the machine knows. Used when detection is stopped and started
    /// again, so that a five-second debounce is not satisfied by a run of microphone
    /// use that happened before Steno was watching.
    public mutating func reset() {
        states.removeAll()
    }
}
