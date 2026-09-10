import Foundation
import StenoCore
import Testing

@testable import Steno

/// Detection above the state machine: the Core Audio glue, the title search, and the
/// path from a trigger to a recording.
///
/// The timings themselves are `StenoCoreTests.MeetingDetectorLogicTests`, driven by a
/// clock a test owns. What is checked here is everything the app adds around them —
/// helper processes grouped onto one watchlist entry, the tap target that comes out,
/// the suggestion appearing before the meeting has a name and gaining one afterwards,
/// a trigger being ignored while a recording runs, and auto-stop writing
/// `stopReason: "auto"`.
@Suite("Meeting detection", .serialized)
@MainActor
struct MeetingDetectionTests {
    private static let teams = WatchedApp(bundleId: "com.microsoft.teams2", name: "Teams")
    private static let chrome = WatchedApp(bundleId: "com.google.Chrome", name: "Chrome")

    private struct Harness {
        let root: URL
        let appState: AppState
        let settings: SettingsStore
        let coordinator: RecordingCoordinator
        let detector: MeetingDetector
        let controller: MeetingDetectionController
        let source: FakeProcessAudioSource
        let suiteName: String

        @MainActor
        func tearDown() {
            controller.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    /// A detector with an invented process list and a title decided in advance.
    ///
    /// The debounce and the auto-stop delay are zero, so one `evaluateNow()` per state
    /// change is the whole clock: the five and thirty seconds are somebody else's test.
    private static func makeHarness(
        title: String? = "Weekly Sync",
        titleDelay: Duration = .zero
    ) -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-detection-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "de.21m.steno.tests.detection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = SettingsStore(defaults: defaults)
        settings.setRootFolder(root)
        settings.settings.autoStopDelay = 0

        let appState = AppState()
        appState.permissions = .allGranted

        let coordinator = RecordingCoordinator(
            appState: appState,
            settings: settings,
            store: RecordingStore(),
            recorder: NullRecorder()
        )

        let source = FakeProcessAudioSource()
        let detector = MeetingDetector(settings: settings, source: source)
        let controller = MeetingDetectionController(
            settings: settings,
            appState: appState,
            coordinator: coordinator,
            detector: detector,
            titleSource: FixedMeetingTitleSource(title, delay: titleDelay)
        )
        return Harness(
            root: root,
            appState: appState,
            settings: settings,
            coordinator: coordinator,
            detector: detector,
            controller: controller,
            source: source,
            suiteName: suiteName
        )
    }

    private static func start(_ harness: Harness) {
        harness.controller.start()
        harness.detector.setTiming(MeetingDetectorTiming(trigger: 0, autoStop: 0, rearm: 60))
    }

    /// Waits for an `@Observable` phase change the coordinator makes in a `Task`.
    private static func settle(_ condition: @escaping () -> Bool, seconds: Double = 3) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Grouping processes onto watchlist entries

    @Test("a helper process counts as its parent app being in a meeting")
    func helperProcessIsTheApp() {
        let processes = [
            AudioProcessDescriptor(pid: 500, bundleId: "com.google.Chrome", isRunningInput: false),
            AudioProcessDescriptor(pid: 501, bundleId: "com.google.Chrome.helper", isRunningInput: true)
        ]
        let matches = RunningMeetingApps.matches(in: processes, watchlist: [Self.chrome])
        #expect(matches.count == 1)
        #expect(matches[0].app == Self.chrome)
        // Only the helper is reading input, so only it is a match …
        #expect(matches[0].pids == [501])
        // … but the tap covers both, because the meeting is played back by whichever
        // process feels like it.
        #expect(
            RunningMeetingApps.target(for: Self.chrome, in: processes)
                == .process(pids: [500, 501], bundleId: "com.google.Chrome", name: "Chrome")
        )
    }

    @Test("an app with no audio process at all falls back to a system-wide tap")
    func missingProcessesFallBack() {
        #expect(RunningMeetingApps.target(for: Self.teams, in: []) == .systemWide)
        #expect(DetectedMeeting(app: Self.teams, pids: []).tapTarget == .systemWide)
    }

    @Test("the detector reports the app, not the process")
    func detectorReportsTheApp() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        var detected: [DetectedMeeting] = []
        harness.detector.onMeetingStarted = { detected.append($0) }
        harness.detector.start()
        harness.detector.setTiming(MeetingDetectorTiming(trigger: 0, autoStop: 0, rearm: 60))

        harness.source.set([
            AudioProcessDescriptor(pid: 500, bundleId: "com.google.Chrome", isRunningInput: false),
            AudioProcessDescriptor(pid: 501, bundleId: "com.google.Chrome.helper", isRunningInput: true)
        ])
        harness.detector.evaluateNow()

        #expect(detected.count == 1)
        #expect(detected.first?.app == Self.chrome)
        #expect(detected.first?.pids == [500, 501])
        #expect(detected.first?.trigger == MeetingTrigger.auto(bundleId: "com.google.Chrome", name: "Chrome"))
        harness.detector.stop()
    }

    // MARK: - The suggestion comes first, the title second

    @Test("the suggestion appears without waiting for the meeting's name")
    func panelDoesNotWaitForTheTitle() async {
        // The title search takes a second here; a Teams call takes up to ten. The panel
        // must be up long before either.
        let harness = Self.makeHarness(titleDelay: .seconds(1))
        defer { harness.tearDown() }
        Self.start(harness)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()

        // Synchronously, in the same turn of the run loop as the trigger.
        #expect(SuggestionPanel.shared.isVisible)
        #expect(!SuggestionPanel.shared.showsTitle)
        #expect(harness.controller.pendingTitle == nil)

        // And the name turns up afterwards, in the headline that is already on screen.
        await Self.settle({ SuggestionPanel.shared.showsTitle }, seconds: 3)
        #expect(SuggestionPanel.shared.showsTitle)
        #expect(harness.controller.pendingTitle == "Weekly Sync")

        SuggestionPanel.shared.answerForTesting(.ignore)
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("a title known before the click names the folder and meta.json")
    func titleBeforeTheAnswer() async throws {
        let harness = Self.makeHarness(title: "Weekly Sync")
        defer { harness.tearDown() }
        Self.start(harness)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        await Self.settle({ SuggestionPanel.shared.showsTitle }, seconds: 3)
        SuggestionPanel.shared.answerForTesting(.record)
        await Self.settle { harness.appState.phase.isRecording }

        let folder = try #require(
            try FileManager.default
                .contentsOfDirectory(at: harness.root, includingPropertiesForKeys: nil)
                .first
        )
        #expect(folder.lastPathComponent.hasSuffix("_Teams_Weekly-Sync"))
        let meta = try MeetingMeta.decode(
            from: try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        )
        #expect(meta.title == "Weekly Sync")
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("a title found after the recording started still reaches meta.json")
    func titleAfterTheAnswer() async throws {
        // The user clicks Aufnehmen at once; the window title turns up seconds later,
        // which is the ordinary case for a Teams call.
        let harness = Self.makeHarness(title: "Weekly Sync", titleDelay: .milliseconds(400))
        defer { harness.tearDown() }
        Self.start(harness)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        #expect(SuggestionPanel.shared.isVisible)
        SuggestionPanel.shared.answerForTesting(.record)
        await Self.settle { harness.appState.phase.isRecording }

        let folder = try #require(
            try FileManager.default
                .contentsOfDirectory(at: harness.root, includingPropertiesForKeys: nil)
                .first
        )
        // The folder was named before the title existed and is not renamed for it: the
        // WAV is open inside it.
        #expect(folder.lastPathComponent.hasSuffix("_Teams"))

        func metaTitle() -> String? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                  let meta = try? MeetingMeta.decode(from: data)
            else { return nil }
            return meta.title
        }
        #expect(metaTitle() == nil)
        await Self.settle({ metaTitle() != nil }, seconds: 3)
        #expect(metaTitle() == "Weekly Sync")
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("an app that never names its window records under the app's name alone")
    func noTitleAtAll() async throws {
        let harness = Self.makeHarness(title: nil)
        defer { harness.tearDown() }
        Self.start(harness)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        #expect(SuggestionPanel.shared.isVisible)
        #expect(!SuggestionPanel.shared.showsTitle)
        SuggestionPanel.shared.answerForTesting(.record)
        await Self.settle { harness.appState.phase.isRecording }

        let folder = try #require(
            try FileManager.default
                .contentsOfDirectory(at: harness.root, includingPropertiesForKeys: nil)
                .first
        )
        #expect(folder.lastPathComponent.hasSuffix("_Teams"))
        let meta = try MeetingMeta.decode(
            from: try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        )
        #expect(meta.title == nil)
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("ignoring records nothing, and the pending title search is dropped")
    func ignoringRecordsNothing() async {
        let harness = Self.makeHarness(title: "Weekly Sync", titleDelay: .milliseconds(400))
        defer { harness.tearDown() }
        Self.start(harness)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        SuggestionPanel.shared.answerForTesting(.ignore)
        #expect(harness.controller.pendingMeeting == nil)

        // Long enough that the title would have arrived, and that a recording would
        // have started if one were going to.
        try? await Task.sleep(for: .milliseconds(700))
        #expect(!harness.appState.phase.isRecording)
        #expect(!SuggestionPanel.shared.isVisible)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: harness.root, includingPropertiesForKeys: nil
        )
        #expect((contents ?? []).isEmpty)
    }

    // MARK: - From the trigger to a recording

    @Test("clicking Aufnehmen starts an online recording of the detected app")
    func answeringRecordStartsRecording() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        Self.start(harness)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        await Self.settle({ SuggestionPanel.shared.showsTitle }, seconds: 3)
        SuggestionPanel.shared.answerForTesting(.record)
        await Self.settle { harness.appState.phase.isRecording }

        #expect(harness.appState.phase.recordingMode == .online)
        #expect(harness.appState.recordingAppName == "Teams")
        #expect(harness.appState.recordingStatusLine?.contains("Teams") == true)

        let folder = try #require(
            try FileManager.default
                .contentsOfDirectory(at: harness.root, includingPropertiesForKeys: nil)
                .first
        )
        #expect(folder.lastPathComponent.hasSuffix("_Teams_Weekly-Sync"))

        let meta = try MeetingMeta.decode(
            from: try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        )
        #expect(meta.mode == .online)
        #expect(meta.title == "Weekly Sync")
        #expect(meta.trigger.kind == .auto)
        #expect(meta.trigger.bundleId == "com.microsoft.teams2")
        #expect(meta.trigger.name == "Teams")
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("nothing is recorded until the question is answered")
    func nothingHappensWithoutAnAnswer() async {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        Self.start(harness)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        // Long enough that a recording would have started if one were going to.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(SuggestionPanel.shared.isVisible)
        #expect(!harness.appState.phase.isRecording)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: harness.root, includingPropertiesForKeys: nil
        )
        #expect((contents ?? []).isEmpty)
        SuggestionPanel.shared.answerForTesting(.ignore)
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("a trigger during a recording is ignored — specification §1")
    func triggerIgnoredWhileRecording() async {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        Self.start(harness)

        harness.coordinator.startOnsite()
        await Self.settle { harness.appState.phase.isRecording }
        #expect(harness.appState.phase.recordingMode == .onsite)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        try? await Task.sleep(for: .milliseconds(300))

        // No question was even asked, and the onsite recording is untouched.
        #expect(!SuggestionPanel.shared.isVisible)
        #expect(harness.appState.phase.recordingMode == .onsite)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: harness.root, includingPropertiesForKeys: nil
        )) ?? []
        #expect(contents.count == 1)
    }

    // MARK: - Auto-stop

    @Test("the app going quiet stops the recording and says so in meta.json")
    func autoStopWritesItsReason() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        Self.start(harness)

        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        SuggestionPanel.shared.answerForTesting(.record)
        await Self.settle { harness.appState.phase.isRecording }

        harness.source.setInput(false, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        await Self.settle { !harness.appState.phase.isRecording }

        let folder = try #require(harness.appState.lastMeetingURL)
        let meta = try MeetingMeta.decode(
            from: try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        )
        // The auto-stop's job ends at the hand-over: `done` is the transcription
        // queue's word, and this harness has none.
        #expect(meta.state == .transcribing)
        #expect(meta.stopReason == .auto)
        #expect(meta.ended != nil)
    }

    @Test("an onsite recording never auto-stops")
    func onsiteNeverAutoStops() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        Self.start(harness)

        harness.coordinator.startOnsite()
        await Self.settle { harness.appState.phase.isRecording }

        // A watched app comes and goes while the room meeting runs.
        harness.source.setInput(true, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        harness.source.setInput(false, bundleId: "com.microsoft.teams2", pid: 4242)
        harness.detector.evaluateNow()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(harness.appState.phase.recordingMode == .onsite)
        harness.coordinator.stop()
        await Self.settle { !harness.appState.phase.isRecording }
        let meta = try MeetingMeta.decode(
            from: try Data(
                contentsOf: try #require(harness.appState.lastMeetingURL)
                    .appendingPathComponent("meta.json")
            )
        )
        #expect(meta.stopReason == .manual)
    }

    @Test("sleep stops the recording with its own reason")
    func sleepStopsWithItsOwnReason() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        Self.start(harness)

        harness.coordinator.startOnsite()
        await Self.settle { harness.appState.phase.isRecording }

        harness.controller.handleWillSleep()
        await Self.settle { !harness.appState.phase.isRecording }

        let meta = try MeetingMeta.decode(
            from: try Data(
                contentsOf: try #require(harness.appState.lastMeetingURL)
                    .appendingPathComponent("meta.json")
            )
        )
        #expect(meta.stopReason == .sleep)
        #expect(meta.state == .transcribing)
    }

    // MARK: - Window titles

    @Test("window titles need Screen Recording, and reading them never throws")
    func windowTitlesAreSafeToAsk() {
        // Not an assertion about what is on screen: only that the reader answers, that
        // it filters by PID, and that asking about nothing gives nothing back.
        #expect(WindowTitleReader.titles(forPIDs: []).isEmpty)
        let own = WindowTitleReader.titles(forPIDs: [ProcessInfo.processInfo.processIdentifier])
        #expect(own.allSatisfy { !$0.isEmpty })
    }

    // MARK: - The suggestion panel

    @Test("the suggestion sits in the top-right corner of the menu-bar screen")
    func panelPlacement() throws {
        let screen = try #require(SuggestionPanel.menuBarScreen)
        let origin = SuggestionPanel.origin(for: SuggestionPanel.size)
        let visible = screen.visibleFrame
        #expect(origin.x == visible.maxX - SuggestionPanel.size.width - SuggestionPanel.margin)
        #expect(origin.y == visible.maxY - SuggestionPanel.size.height - SuggestionPanel.margin)
        // Inside the usable area, i.e. below the menu bar and not off the right edge.
        #expect(origin.x + SuggestionPanel.size.width <= visible.maxX)
        #expect(origin.y + SuggestionPanel.size.height <= visible.maxY)
    }

    @Test("the panel answers, disappears, and answers only once")
    func panelAnswers() async {
        var answers: [SuggestionPanel.Answer] = []
        SuggestionPanel.shared.show(appName: "Teams", title: "Weekly Sync", timeout: 30) {
            answers.append($0)
        }
        #expect(SuggestionPanel.shared.isVisible)
        #expect(SuggestionPanel.shared.frameDescription != nil)

        SuggestionPanel.shared.answerForTesting(.record)
        #expect(answers == [.record])
        #expect(!SuggestionPanel.shared.isVisible)

        SuggestionPanel.shared.answerForTesting(.ignore)
        #expect(answers == [.record])
        // Let the fade-out finish before the next test opens one.
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("the headline gains the meeting's name without the panel going away")
    func panelGainsTheTitle() async {
        var answers: [SuggestionPanel.Answer] = []
        SuggestionPanel.shared.show(appName: "Teams", title: nil, timeout: 30) {
            answers.append($0)
        }
        #expect(SuggestionPanel.shared.isVisible)
        #expect(!SuggestionPanel.shared.showsTitle)

        SuggestionPanel.shared.updateTitle("Weekly Sync")
        #expect(SuggestionPanel.shared.showsTitle)
        // Still the same panel, still waiting for the same answer.
        #expect(SuggestionPanel.shared.isVisible)
        #expect(answers.isEmpty)

        SuggestionPanel.shared.answerForTesting(.record)
        #expect(answers == [.record])
        // And a title arriving after the panel is gone is dropped rather than kept.
        SuggestionPanel.shared.updateTitle("Zu spät")
        #expect(!SuggestionPanel.shared.showsTitle)
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("a timeout is an ignore")
    func panelTimesOut() async {
        var answers: [SuggestionPanel.Answer] = []
        SuggestionPanel.shared.show(appName: "Zoom", title: nil, timeout: 0.2) {
            answers.append($0)
        }
        await Self.settle({ !answers.isEmpty }, seconds: 3)
        #expect(answers == [.ignore])
        #expect(!SuggestionPanel.shared.isVisible)
        try? await Task.sleep(for: .milliseconds(250))
    }
}
