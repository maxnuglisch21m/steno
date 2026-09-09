import Foundation
import StenoCore
import Testing

@testable import Steno

/// The queue's bookkeeping: what it remembers across a launch, and what it refuses.
///
/// The pipeline itself — splitter, models, merge — is not exercised here. It needs a
/// 2.5 GB checkpoint and minutes of Neural Engine time, which is not a unit test; the
/// pieces that can be tested without it have their own suites, and the whole is checked
/// end to end with `--transcribe`.
@Suite("TranscriptionQueue", .serialized)
@MainActor
struct TranscriptionQueueTests {
    private struct Harness {
        let root: URL
        let appState: AppState
        let settings: SettingsStore
        let store: TranscriptionQueueStore
        let queue: TranscriptionQueue
        let suiteName: String

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        /// A meeting folder with a `meta.json` in the given state and no audio, so that
        /// anything that reaches the pipeline fails fast instead of loading models.
        @discardableResult
        func makeMeeting(named name: String, state: MeetingState) throws -> URL {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            var meta = MeetingMeta(
                mode: .onsite,
                started: Date(),
                trigger: .manual,
                input: AudioInputInfo(device: "Test"),
                app: "0.1.0"
            )
            meta.finishCapture(at: Date(), reason: .manual)
            if state != .recording {
                try meta.transition(to: .transcribing)
            }
            if state == .done { try meta.transition(to: .done) }
            if state == .failed { try meta.fail(reason: "for the test") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try meta.jsonData().write(to: folder.appendingPathComponent("meta.json"))
            return folder
        }
    }

    private static func makeHarness() -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "de.21m.steno.tests.queue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = SettingsStore(defaults: defaults)
        settings.setRootFolder(root)
        // Nothing in these tests should ever post a banner; the setting says so as well
        // as the authorization does.
        settings.settings.notificationsEnabled = false

        let appState = AppState()
        let store = TranscriptionQueueStore(defaults: defaults)
        let queue = TranscriptionQueue(
            appState: appState,
            settings: settings,
            // A model manager pointed at an empty directory: nothing here gets far
            // enough to load from it.
            models: ModelManager(directory: root.appendingPathComponent("models")),
            store: store
        )
        return Harness(
            root: root,
            appState: appState,
            settings: settings,
            store: store,
            queue: queue,
            suiteName: suiteName
        )
    }

    private static func waitUntil(
        _ description: Comment,
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for \(description)")
    }

    // MARK: - Persistence

    @Test("a queued folder is written down, so a relaunch can pick it up")
    func persistsTheQueue() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let folder = try harness.makeMeeting(named: "2026-09-09_1430_Vorort", state: .transcribing)

        harness.queue.enqueue(folder)

        // Written before any work starts: a crash one second later must not lose it.
        #expect(harness.store.load().paths.contains(folder.standardizedFileURL.stenoPath))

        try await Self.waitUntil("the folder to be worked through") {
            harness.store.load().isEmpty
        }
    }

    @Test("a folder is taken out of the queue once it has been worked on")
    func removesFinishedWork() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let folder = try harness.makeMeeting(named: "2026-09-09_1430_Vorort", state: .transcribing)

        harness.queue.enqueue(folder)
        try await Self.waitUntil("the queue to empty") { harness.store.load().isEmpty }

        // It has no audio, so it fails — and a failed folder is still finished work.
        #expect(harness.queue.current == nil)
        #expect(harness.appState.phase == .idle)
    }

    @Test("a folder with no audio fails with a reason instead of hanging")
    func failsWithoutAudio() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let folder = try harness.makeMeeting(named: "2026-09-09_1430_Vorort", state: .transcribing)

        harness.queue.enqueue(folder)
        try await Self.waitUntil("the folder to fail") {
            harness.appState.lastMeetingState == .failed
        }

        let meta = try MeetingMeta.decode(
            from: try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        )
        #expect(meta.state == .failed)
        #expect(!(meta.error ?? "").isEmpty)
        // `_work` was never created, so there is nothing to keep for diagnosis.
        #expect(
            !FileManager.default.fileExists(
                atPath: ChannelSplitter.workDirectory(in: folder).stenoPath
            )
        )
    }

    @Test("the leftovers of the last launch are picked up again")
    func resumesPersistedWork() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let folder = try harness.makeMeeting(named: "2026-09-09_1430_Vorort", state: .transcribing)

        // What the previous launch would have left behind.
        var state = TranscriptionQueueState.empty
        state.enqueue(folder.standardizedFileURL.stenoPath)
        harness.store.save(state)

        harness.queue.resumePersisted()
        try await Self.waitUntil("the leftover folder to be worked through") {
            harness.store.load().isEmpty
        }
        #expect(harness.appState.lastMeetingURL == folder)
    }

    @Test("a folder the user deleted between launches is dropped, not chased")
    func dropsMissingFolders() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }

        var state = TranscriptionQueueState.empty
        state.enqueue(harness.root.appendingPathComponent("gone").stenoPath)
        harness.store.save(state)

        harness.queue.resumePersisted()

        #expect(harness.store.load().isEmpty)
    }

    @Test("the same folder handed over twice is queued once")
    func doesNotQueueTwice() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let folder = harness.root.appendingPathComponent("2026-09-09_1430_Vorort", isDirectory: true)

        var state = TranscriptionQueueState.empty
        state.enqueue(folder.standardizedFileURL.stenoPath)
        #expect(state.enqueue(folder.standardizedFileURL.stenoPath) == false)
        #expect(state.count == 1)
    }

    // MARK: - Reprocessing

    @Test("a failed meeting can be handed back for another try")
    func reprocessesAFailedMeeting() async throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let folder = try harness.makeMeeting(named: "2026-09-09_1430_Vorort", state: .failed)

        harness.queue.reprocess(folder)

        // failed → transcribing is the one transition back into the pipeline, and it
        // has to be written before the work starts so a crash leaves it queued.
        try await Self.waitUntil("the retry to run") { harness.appState.lastMeetingURL == folder }
    }

    @Test("a finished meeting is not reprocessed over the top of its transcript")
    func refusesToReprocessDone() {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let folder = try! harness.makeMeeting(named: "2026-09-09_1430_Vorort", state: .done)

        harness.queue.reprocess(folder)

        #expect(harness.store.load().isEmpty)
        #expect(harness.appState.notice != nil)
    }

    // MARK: - Progress

    @Test("the four steps divide the ring between them, in order and without gaps")
    func stepsCoverTheRing() {
        var previous: Double = 0
        for step in TranscriptionQueue.Step.allCases {
            #expect(step.range.lowerBound == previous)
            #expect(step.range.upperBound > step.range.lowerBound)
            previous = step.range.upperBound
        }
        #expect(previous == 1)
        #expect(TranscriptionQueue.Step.count == 4)
    }

    @Test("every step names itself in the menu bar")
    func stepLabels() {
        for step in TranscriptionQueue.Step.allCases {
            let label = step.localizedLabel
            #expect(label.contains("\(step.rawValue)/4"))
            #expect(label.contains(step.localizedName))
        }
    }
}
