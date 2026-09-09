import Foundation
import StenoCore
import Testing

@testable import Steno

/// The whole M0 recording flow, driven end to end against `NullRecorder` in a
/// temporary root: folder created, `meta.json` written at every state change, channels
/// matching the mode, and the start gate refusing for the right reason.
@Suite("RecordingCoordinator", .serialized)
@MainActor
struct RecordingCoordinatorTests {
    /// Stands in for the transcription queue.
    ///
    /// M5 moved the end of the recording flow: the coordinator no longer declares a
    /// folder `done`, it hands one over that says `transcribing`. What is checked here
    /// is that hand-over — the models, the splitter, and the merge have tests of their
    /// own and have no business inside a recording test.
    @MainActor
    final class QueueSpy: TranscriptionEnqueuing {
        private let appState: AppState
        private(set) var enqueued: [URL] = []

        init(appState: AppState) {
            self.appState = appState
        }

        func enqueue(_ folder: URL) {
            enqueued.append(folder)
            // The real queue owns the phase from the hand-over onwards, and returns it
            // to idle when the last folder is finished. This one has nothing to do, so
            // it does that immediately.
            appState.phase = .idle
        }
    }

    /// One coordinator, its state, and a throwaway recording root.
    private struct Harness {
        let root: URL
        let appState: AppState
        let settings: SettingsStore
        let store: RecordingStore
        let coordinator: RecordingCoordinator
        let queue: QueueSpy
        let suiteName: String

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    @MainActor
    private static func makeHarness(
        permissions: PermissionSnapshot = .allGranted
    ) -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-tests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "de.21m.steno.tests.coordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = SettingsStore(defaults: defaults)
        settings.setRootFolder(root)

        let appState = AppState()
        appState.permissions = permissions

        let store = RecordingStore()
        let coordinator = RecordingCoordinator(
            appState: appState,
            settings: settings,
            store: store,
            recorder: NullRecorder()
        )
        let queue = QueueSpy(appState: appState)
        coordinator.transcription = queue
        return Harness(
            root: root,
            appState: appState,
            settings: settings,
            store: store,
            coordinator: coordinator,
            queue: queue,
            suiteName: suiteName
        )
    }

    /// Waits until `condition` holds, letting the coordinator's tasks run in between.
    private static func waitUntil(
        _ description: Comment,
        timeout: Duration = .seconds(15),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for \(description)")
    }

    // MARK: - The flow

    @Test(
        "a recording produces a folder handed to transcription with the mode's channels",
        arguments: [MeetingMode.onsite, MeetingMode.online]
    )
    func recordsThroughToDone(mode: MeetingMode) async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.start(mode: mode, trigger: .manual)
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        #expect(harness.appState.phase.recordingMode == mode)

        // While recording, meta.json already says so — that is what makes a crash
        // during the recording recognizable on the next launch.
        let folder = try #require(
            harness.store.meetingFolders(in: harness.root).first,
            "the meeting folder should exist while recording"
        )
        let midway = try Self.readMeta(in: folder)
        #expect(midway.state == .recording)
        #expect(midway.ended == nil)
        #expect(midway.mode == mode)

        harness.coordinator.stop()
        try await Self.waitUntil("the recording to finish") {
            harness.appState.lastMeetingURL != nil && harness.appState.phase == .idle
        }

        let meta = try Self.readMeta(in: folder)
        // `transcribing`, not `done`: the transcript is what makes a meeting done, and
        // the queue is what writes it. A folder that said `done` here would be lying
        // about a transcript that does not exist.
        #expect(meta.state == .transcribing)
        // Compared standardized: the temporary root is under `/var`, which is a symlink
        // to `/private/var`, and the two spellings are the same folder.
        #expect(harness.queue.enqueued.map(\.standardizedFileURL) == [folder.standardizedFileURL])
        #expect(meta.mode == mode)
        #expect(meta.channels == mode.channels)
        #expect(meta.trigger.kind == .manual)
        #expect(meta.ended != nil)
        #expect((meta.duration ?? -1) >= 0)
        #expect(meta.app == AppVersion.marketing)
        #expect(meta.appBuild == AppVersion.build)
        #expect(!(meta.os ?? "").isEmpty)
        // NullRecorder writes no audio, and meta.json says so rather than pointing at
        // a file that is not there.
        #expect(meta.audio == nil)
    }

    @Test("the folder is named for the mode")
    func namesFolderForMode() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Self.waitUntil("onsite to start") { harness.appState.phase.isRecording }
        harness.coordinator.stop()
        try await Self.waitUntil("onsite to finish") { harness.appState.lastMeetingURL != nil }

        let name = try #require(harness.appState.lastMeetingURL?.lastPathComponent)
        #expect(name.hasSuffix("_Vorort"))
        #expect(RecordingFolderName.matches(name))
    }

    @Test("an online recording with no known app is named Online")
    func namesOnlineFolder() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        // An empty watchlist is what "no known app" means: nothing can match, so the
        // tap is system-wide and the folder is named for the mode. Without this the
        // test would depend on whether a browser on the real watchlist happens to be
        // holding the microphone on the machine running it.
        harness.settings.settings.watchlist = []

        harness.coordinator.startOnline()
        try await Self.waitUntil("online to start") { harness.appState.phase.isRecording }
        harness.coordinator.stop()
        try await Self.waitUntil("online to finish") { harness.appState.lastMeetingURL != nil }

        let name = try #require(harness.appState.lastMeetingURL?.lastPathComponent)
        #expect(name.hasSuffix("_Online"))
    }

    @Test("a second start while recording is ignored")
    func ignoresSecondStart() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the first recording to start") { harness.appState.phase.isRecording }
        let started = harness.appState.phase.startedAt

        // Specification §1: while a recording runs, new triggers are ignored.
        harness.coordinator.startOnline()
        harness.coordinator.startOnsite()
        try await Task.sleep(for: .milliseconds(200))

        #expect(harness.appState.phase.startedAt == started)
        #expect(harness.appState.phase.recordingMode == .onsite)
        #expect(harness.store.meetingFolders(in: harness.root).count == 1)

        harness.coordinator.stop()
        try await Self.waitUntil("it to finish") { harness.appState.lastMeetingURL != nil }
    }

    @Test("a stop pressed during the start is honoured, not dropped")
    func stopDuringStart() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        // ⌥⌘R and ⌥⌘S in quick succession: the second arrives while the microphone is
        // still being opened. Dropping it would leave a recording running that the
        // user believes they stopped.
        harness.coordinator.startOnsite()
        harness.coordinator.stop()

        try await Self.waitUntil("the recording to start and stop again") {
            harness.appState.lastMeetingURL != nil && harness.appState.phase == .idle
        }
        let folder = try #require(harness.appState.lastMeetingURL)
        let meta = try Self.readMeta(in: folder)
        #expect(meta.state == .transcribing)
        #expect(meta.ended != nil)
    }

    @Test("a recording with nowhere to hand the folder still finishes cleanly")
    func withoutATranscriptionQueue() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        // The queue is a dependency, not a requirement: a build without one — the
        // tests, and every path that runs before the models exist — must still end the
        // recording, close the file, and go back to idle rather than hanging in
        // `processing` for ever.
        harness.coordinator.transcription = nil

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        harness.coordinator.stop()
        try await Self.waitUntil("it to finish") {
            harness.appState.lastMeetingURL != nil && harness.appState.phase == .idle
        }

        let folder = try #require(harness.appState.lastMeetingURL)
        #expect(try Self.readMeta(in: folder).state == .transcribing)
        #expect(harness.queue.enqueued.isEmpty)
    }

    @Test("stopping when nothing runs does nothing")
    func stopWithoutRecording() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.appState.phase == .idle)
        #expect(harness.appState.lastMeetingURL == nil)
    }

    @Test("the recording root is created on the way in")
    func createsRoot() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        #expect(!FileManager.default.fileExists(atPath: harness.root.stenoPath))

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the root to appear") {
            FileManager.default.fileExists(atPath: harness.root.stenoPath)
        }
        harness.coordinator.stop()
        try await Self.waitUntil("it to finish") { harness.appState.lastMeetingURL != nil }
    }

    // MARK: - The start gate

    @Test("canStart names the missing permission")
    func blocksOnMissingMicrophone() {
        var snapshot = PermissionSnapshot.allGranted
        snapshot.microphone = .denied
        let harness = Self.makeHarness(permissions: snapshot)
        defer { harness.tearDown() }

        #expect(harness.coordinator.canStart(mode: .onsite) == .missingPermission(.microphone))
        #expect(harness.coordinator.canStart(mode: .online) == .missingPermission(.microphone))
    }

    @Test("system audio blocks online only")
    func systemAudioBlocksOnlineOnly() {
        var snapshot = PermissionSnapshot.allGranted
        snapshot.systemAudio = .undetermined
        let harness = Self.makeHarness(permissions: snapshot)
        defer { harness.tearDown() }

        #expect(harness.coordinator.canStart(mode: .online) == .missingPermission(.systemAudio))
        // An on-site recording needs no tap, so it is not blocked by one.
        #expect(harness.coordinator.canStart(mode: .onsite) == nil)
    }

    @Test("screen recording blocks both modes, because both take screenshots")
    func screenRecordingBlocksBoth() {
        var snapshot = PermissionSnapshot.allGranted
        snapshot.screenRecording = .undetermined
        let harness = Self.makeHarness(permissions: snapshot)
        defer { harness.tearDown() }

        #expect(harness.coordinator.canStart(mode: .online) == .missingPermission(.screenRecording))
        #expect(harness.coordinator.canStart(mode: .onsite) == .missingPermission(.screenRecording))
    }

    @Test("missing models do not block a recording")
    func modelsDoNotBlock() {
        var snapshot = PermissionSnapshot.allGranted
        snapshot.models = .undetermined
        let harness = Self.makeHarness(permissions: snapshot)
        defer { harness.tearDown() }

        // Capture happens now; transcription happens later, and can wait for a download.
        #expect(harness.coordinator.canStart(mode: .onsite) == nil)
        #expect(harness.coordinator.canStart(mode: .online) == nil)
    }

    @Test("the microphone is named before system audio, in onboarding order")
    func reportsTheFirstMissingPermission() {
        var snapshot = PermissionSnapshot.allGranted
        snapshot.microphone = .denied
        snapshot.systemAudio = .denied
        let harness = Self.makeHarness(permissions: snapshot)
        defer { harness.tearDown() }

        #expect(harness.coordinator.canStart(mode: .online) == .missingPermission(.microphone))
    }

    @Test("a refused start writes no folder and says why")
    func refusedStartLeavesNothingBehind() async throws {
        var snapshot = PermissionSnapshot.allGranted
        snapshot.microphone = .denied
        let harness = Self.makeHarness(permissions: snapshot)
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Task.sleep(for: .milliseconds(200))

        #expect(harness.appState.phase == .idle)
        #expect(harness.store.meetingFolders(in: harness.root).isEmpty)
        #expect(harness.appState.notice?.contains(Permission.microphone.title) == true)
    }

    @Test("canStart refuses while a recording runs")
    func blocksWhileRecording() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        #expect(harness.coordinator.canStart(mode: .onsite) == .alreadyRecording)
        #expect(harness.coordinator.canStart(mode: .online) == .alreadyRecording)

        harness.coordinator.stop()
        try await Self.waitUntil("it to finish") { harness.appState.lastMeetingURL != nil }
        #expect(harness.coordinator.canStart(mode: .onsite) == nil)
    }

    @Test("every blocker has a sentence to show")
    func blockersAreAllLocalized() {
        let blockers: [StartBlocker] = [
            .alreadyRecording,
            .processing,
            .missingPermission(.systemAudio),
            .notEnoughDiskSpace(freeBytes: 42_000_000),
            .rootFolderUnavailable("nope")
        ]
        for blocker in blockers {
            #expect(!blocker.localizedReason.isEmpty)
        }
        #expect(StartBlocker.missingPermission(.models).permission == .models)
        #expect(StartBlocker.alreadyRecording.permission == nil)
    }

    // MARK: - Helpers

    private static func readMeta(in folder: URL) throws -> MeetingMeta {
        let data = try Data(contentsOf: folder.appendingPathComponent(RecordingStore.metaFileName))
        return try MeetingMeta.decode(from: data)
    }
}
