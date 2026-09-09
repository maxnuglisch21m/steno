import Foundation
import StenoCore
import Testing

@testable import Steno

/// What happens when the audio layer stops answering.
///
/// Not a hypothetical. `coreaudiod` can get into a state where every call that opens
/// an input blocks inside the daemon forever — a tap left behind by a process that was
/// killed at the wrong moment is one way in — and nothing in Core Audio has a timeout
/// of its own. Without a deadline the coordinator would sit in `isTransitioning`
/// forever: the menu would show idle, refuse every start with "a recording is already
/// running", and only a relaunch would clear it.
///
/// So both halves are on a clock, and both end in a folder that says what happened.
@Suite("Recorder deadlines", .serialized)
@MainActor
struct RecorderTimeoutTests {
    // MARK: - A recorder that does not answer

    /// A recorder that takes as long as it is told to.
    ///
    /// It writes the audio file on the way in, like a real one, so that the cleanup
    /// after an abandoned start has something to remove.
    private actor SlowRecorder: AudioRecorder {
        let startDelay: Duration
        let stopDelay: Duration
        private(set) var stopCount = 0
        private(set) var didStart = false

        init(startDelay: Duration = .zero, stopDelay: Duration = .zero) {
            self.startDelay = startDelay
            self.stopDelay = stopDelay
        }

        func start(_ configuration: AudioRecorderConfiguration) async throws -> AudioRecorderStart {
            FileManager.default.createFile(
                atPath: configuration.folder.appendingPathComponent(WAVWriter.fileName).stenoPath,
                contents: Data("RIFF".utf8)
            )
            try? await Task.sleep(for: startDelay)
            didStart = true
            return AudioRecorderStart(deviceName: "Fake", microphoneMode: nil)
        }

        func stop() async throws -> AudioRecorderOutcome {
            stopCount += 1
            try? await Task.sleep(for: stopDelay)
            return AudioRecorderOutcome(
                audioFileName: WAVWriter.fileName,
                channels: MeetingMode.online.channels,
                frameCount: 48_000,
                duration: 1
            )
        }
    }

    private struct Harness {
        let root: URL
        let appState: AppState
        let settings: SettingsStore
        let store: RecordingStore
        let coordinator: RecordingCoordinator
        let suiteName: String

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    private static func makeHarness(recorder: any AudioRecorder) -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-tests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "de.21m.steno.tests.timeout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = SettingsStore(defaults: defaults)
        settings.setRootFolder(root)
        // No watchlist, so the `online` tap target is decided without depending on
        // whatever happens to be holding the microphone on the machine running this.
        settings.settings.watchlist = []

        let appState = AppState()
        appState.permissions = .allGranted

        let coordinator = RecordingCoordinator(
            appState: appState,
            settings: settings,
            store: RecordingStore(),
            recorder: recorder
        )
        return Harness(
            root: root,
            appState: appState,
            settings: settings,
            store: RecordingStore(),
            coordinator: coordinator,
            suiteName: suiteName
        )
    }

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

    private static func readMeta(in folder: URL) throws -> MeetingMeta {
        let data = try Data(contentsOf: folder.appendingPathComponent(RecordingStore.metaFileName))
        return try MeetingMeta.decode(from: data)
    }

    /// The one sentence both timeouts produce, and the only one that tells the user
    /// what actually fixes it.
    private static var timeoutReason: String { RecorderTimeout.start.localizedDescription }

    // MARK: - Starting

    @Test("a start that never answers ends as failed, not as a frozen menu")
    func startTimeout() async throws {
        let recorder = SlowRecorder(startDelay: .seconds(2))
        let harness = Self.makeHarness(recorder: recorder)
        defer { harness.tearDown() }
        harness.coordinator.setRecorderTimeouts(start: .milliseconds(200), stop: .seconds(5))

        harness.coordinator.start(mode: .online, trigger: .manual)
        try await Self.waitUntil("the start to be given up on") {
            harness.appState.notice == Self.timeoutReason
        }

        // Never recording, and — the point of the whole exercise — not stuck
        // transitioning either: the next start is allowed.
        #expect(harness.appState.phase == .idle)
        #expect(harness.coordinator.canStart(mode: .online) == nil)

        let folder = try #require(harness.store.meetingFolders(in: harness.root).first)
        let meta = try Self.readMeta(in: folder)
        #expect(meta.state == .failed)
        #expect(meta.error == Self.timeoutReason)
        #expect(meta.error?.contains("coreaudiod") == true)

        // The late start is cleaned up after itself: the hardware is released and the
        // file it opened is removed, rather than a microphone staying live behind an
        // idle menu and a stray `audio.wav` no `meta.json` mentions.
        let audio = folder.appendingPathComponent(WAVWriter.fileName)
        try await Self.waitUntil("the abandoned recording to be cleaned up") {
            !FileManager.default.fileExists(atPath: audio.stenoPath)
        }
        #expect(await recorder.stopCount == 1)
        #expect(await recorder.didStart)
    }

    @Test("a start that answers in time is not affected by the deadline")
    func startWithinDeadline() async throws {
        let recorder = SlowRecorder(startDelay: .milliseconds(50))
        let harness = Self.makeHarness(recorder: recorder)
        defer { harness.tearDown() }
        harness.coordinator.setRecorderTimeouts(start: .seconds(5), stop: .seconds(5))

        harness.coordinator.start(mode: .online, trigger: .manual)
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        harness.coordinator.stop()
        try await Self.waitUntil("the recording to finish") { harness.appState.phase == .idle }

        let folder = try #require(harness.store.meetingFolders(in: harness.root).first)
        // `transcribing`: the recording is complete and has been handed over. `done` is
        // the transcription queue's word, and this harness has none.
        #expect(try Self.readMeta(in: folder).state == .transcribing)
    }

    // MARK: - Stopping

    @Test("a stop that never answers still finishes the folder, and keeps the audio")
    func stopTimeout() async throws {
        let recorder = SlowRecorder(stopDelay: .seconds(2))
        let harness = Self.makeHarness(recorder: recorder)
        defer { harness.tearDown() }
        harness.coordinator.setRecorderTimeouts(start: .seconds(5), stop: .milliseconds(200))

        harness.coordinator.start(mode: .online, trigger: .manual)
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }

        harness.coordinator.stop()
        try await Self.waitUntil("the stop to be given up on") { harness.appState.phase == .idle }

        #expect(harness.appState.notice == Self.timeoutReason)
        #expect(harness.coordinator.canStart(mode: .online) == nil)

        let folder = try #require(harness.store.meetingFolders(in: harness.root).first)
        let meta = try Self.readMeta(in: folder)
        // `failed`, not `done`: nothing here knows whether the recording is complete,
        // and a folder that says so plainly is worth more than one that claims a clean
        // ending it cannot vouch for.
        #expect(meta.state == .failed)
        #expect(meta.error == Self.timeoutReason)
        #expect(meta.ended != nil)
        #expect((meta.duration ?? -1) >= 0)
        // What reached the disk stays, and `meta.json` names it.
        #expect(meta.audio == WAVWriter.fileName)
        #expect(meta.channels == MeetingMode.online.channels)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(WAVWriter.fileName).stenoPath))
    }

    // MARK: - The deadline itself

    @Test("a deadline hands back the value when the operation is quick")
    func deadlineFinishes() async {
        let outcome = await Deadline.run(.seconds(5)) { 42 }
        #expect(outcome.value == 42)
    }

    @Test("a deadline hands back the error when the operation fails")
    func deadlineFails() async {
        struct Boom: Error {}
        let outcome = await Deadline.run(.seconds(5)) { throw Boom() }
        guard case .finished(.failure) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(outcome.value == nil)
    }

    @Test("a deadline that expires hands back the task, still running")
    func deadlineTimesOut() async throws {
        let outcome = await Deadline.run(.milliseconds(50)) {
            try await Task.sleep(for: .milliseconds(400))
            return 7
        }
        guard case .timedOut(let task) = outcome else {
            Issue.record("expected a timeout, got \(outcome)")
            return
        }
        // Abandoned, not cancelled: the caller is the one that decides what to do with
        // an operation that eventually comes back.
        #expect(try await task.value == 7)
    }
}
