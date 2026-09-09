import Foundation
import StenoCore
import Testing

@testable import Steno

/// A recorder that writes nothing but can be interrupted on demand.
///
/// Device loss cannot be provoked in a test — it needs a cable to be pulled — so what
/// is checked is the half that is Steno's: given the interruption, does the folder end
/// up in a state a downstream tool and M6's recovery pass can both make sense of.
actor FakeInterruptibleRecorder: AudioRecorder {
    private var interruptionHandler: (@Sendable (AudioInterruptionReason) -> Void)?
    private var mode: MeetingMode = .onsite
    private(set) var isRunning = false
    private(set) var stopCount = 0

    func start(_ configuration: AudioRecorderConfiguration) async throws -> AudioRecorderStart {
        interruptionHandler = configuration.onInterruption
        mode = configuration.mode
        isRunning = true
        return AudioRecorderStart(
            deviceName: "Tisch-Grenzflächenmikrofon",
            microphoneMode: MicrophoneMode.wideSpectrum.metaValue
        )
    }

    func stop() async throws -> AudioRecorderOutcome {
        isRunning = false
        stopCount += 1
        // Even an interrupted recording leaves audio behind, and `meta.json` has to
        // name it: a short recording is worth transcribing, a missing one is not.
        return AudioRecorderOutcome(
            audioFileName: WAVWriter.fileName,
            channels: mode.channels,
            frameCount: 480_000,
            duration: 10
        )
    }

    /// Fires the callback the coordinator installed, the way a lost device would.
    func interrupt(_ reason: AudioInterruptionReason) {
        interruptionHandler?(reason)
    }
}

@Suite(
    "Recording interruptions",
    .serialized,
    // Every start here goes through the real §3b.1 gate, which refuses on a Mac whose
    // microphone is set to Voice Isolation. That refusal has its own tests.
    .enabled(
        if: !MicrophoneModeCheck.decision(for: MicrophoneModeCheck.active()).isBlocking,
        "Voice Isolation is active on this Mac"
    )
)
@MainActor
struct RecordingInterruptionTests {
    private struct Harness {
        let root: URL
        let appState: AppState
        let settings: SettingsStore
        let store: RecordingStore
        let coordinator: RecordingCoordinator
        let recorder: FakeInterruptibleRecorder
        let suiteName: String

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    private static func makeHarness() -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-tests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "de.21m.steno.tests.interruption.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = SettingsStore(defaults: defaults)
        settings.setRootFolder(root)

        let appState = AppState()
        appState.permissions = .allGranted

        let recorder = FakeInterruptibleRecorder()
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
            recorder: recorder,
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

    // MARK: - Device loss

    @Test("a lost input device ends the recording in failed, with the reason")
    func deviceLossFails() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        let folder = try #require(harness.store.meetingFolders(in: harness.root).first)

        let reason = AudioInterruptionReason.inputDeviceLost(device: "Tisch-Grenzflächenmikrofon")
        await harness.recorder.interrupt(reason)

        try await Self.waitUntil("the recording to end") { harness.appState.phase == .idle }

        let meta = try Self.readMeta(in: folder)
        #expect(meta.state == .failed)
        #expect(meta.error == reason.localizedReason)
        // The audio that was captured is named and dated: a partial recording is
        // still a recording, and M6 has to be able to find and finish it.
        #expect(meta.audio == "audio.wav")
        #expect(meta.channels == [.room])
        #expect(meta.ended != nil)
        #expect((meta.duration ?? -1) >= 0)

        // And the hardware was released, rather than left holding the microphone.
        #expect(await harness.recorder.stopCount == 1)
        #expect(await harness.recorder.isRunning == false)
        #expect(harness.appState.notice == reason.localizedReason)
        // Compared by name: the temporary directory reaches the two sides through
        // different symlinks (`/var` and `/private/var`).
        #expect(harness.appState.lastMeetingURL?.lastPathComponent == folder.lastPathComponent)
    }

    @Test("a failed write ends the recording the same way")
    func writeFailureFails() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        let folder = try #require(harness.store.meetingFolders(in: harness.root).first)

        // What a full volume looks like from the coordinator's side.
        let reason = AudioInterruptionReason.writeFailed("No space left on device")
        await harness.recorder.interrupt(reason)
        try await Self.waitUntil("the recording to end") { harness.appState.phase == .idle }

        let meta = try Self.readMeta(in: folder)
        #expect(meta.state == .failed)
        #expect(meta.error?.contains("No space left on device") == true)
    }

    @Test("a second interruption after the first is ignored")
    func ignoresLateInterruptions() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        let folder = try #require(harness.store.meetingFolders(in: harness.root).first)

        await harness.recorder.interrupt(.captureStopped("first"))
        try await Self.waitUntil("the recording to end") { harness.appState.phase == .idle }
        await harness.recorder.interrupt(.captureStopped("second"))
        try await Task.sleep(for: .milliseconds(200))

        let meta = try Self.readMeta(in: folder)
        // `failed → failed` is not a legal transition, so a second one would either
        // throw or overwrite the first reason. Neither may happen.
        #expect(meta.state == .failed)
        #expect(meta.error?.contains("first") == true)
        #expect(await harness.recorder.stopCount == 1)
    }

    @Test("stopping after an interruption does nothing")
    func stopAfterInterruption() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        await harness.recorder.interrupt(.inputDeviceLost(device: "Poly BT700"))
        try await Self.waitUntil("the recording to end") { harness.appState.phase == .idle }

        harness.coordinator.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.appState.phase == .idle)
        #expect(await harness.recorder.stopCount == 1)
    }

    @Test("an ordinary stop reaches transcribing and names the audio")
    func ordinaryStopIsUnaffected() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        harness.coordinator.startOnsite()
        try await Self.waitUntil("the recording to start") { harness.appState.phase.isRecording }
        let folder = try #require(harness.store.meetingFolders(in: harness.root).first)

        harness.coordinator.stop()
        try await Self.waitUntil("the recording to finish") { harness.appState.phase == .idle }

        let meta = try Self.readMeta(in: folder)
        #expect(meta.state == .transcribing)
        #expect(meta.audio == "audio.wav")
        #expect(meta.channels == [.room])
        // Whatever the recorder reported about the hardware is what meta.json says.
        #expect(meta.input.device == "Tisch-Grenzflächenmikrofon")
        #expect(meta.input.microphoneMode == "wideSpectrum")
    }

    // MARK: - Every reason has something to show

    @Test("every interruption reason has a sentence")
    func reasonsAreLocalized() {
        let reasons: [AudioInterruptionReason] = [
            .inputDeviceLost(device: "Poly BT700"),
            .captureStopped("engine"),
            .writeFailed("disk")
        ]
        for reason in reasons {
            #expect(!reason.localizedReason.isEmpty)
        }
        #expect(AudioInterruptionReason.inputDeviceLost(device: "X").localizedReason.contains("X"))
    }
}
