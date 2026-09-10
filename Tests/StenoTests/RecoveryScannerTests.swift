import AVFoundation
import Darwin
import Foundation
import StenoCore
import Testing

@testable import Steno

/// M6: what the launch-time scan does to a recording root full of folders in every
/// state a crash can leave them in.
///
/// The decision table itself is `StenoCore.RecoveryPolicyTests`; what is checked here is
/// everything the table cannot see — that the WAV header is really rewritten in place,
/// that a half-written `screens.jsonl` line is really cut off, that `meta.json` comes out
/// saying `crash`, and that a folder somebody else is recording into is really left
/// alone.
@Suite("RecoveryScanner")
@MainActor
struct RecoveryScannerTests {
    // MARK: - A recording root to scan

    private struct Root {
        let url: URL
        let suiteName: String
        let defaults: UserDefaults
        let queueStore: TranscriptionQueueStore
        let scanner: RecoveryScanner

        func tearDown() {
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: suiteName)
        }

        /// A meeting folder in a given state, with as much or as little in it as the
        /// case being tested needs.
        @discardableResult
        func makeMeeting(
            named name: String,
            state: MeetingState,
            mode: MeetingMode = .onsite,
            audio: AudioFixture = .none,
            indexLines: [String] = [],
            lock: MeetingLock? = nil,
            started: Date = Date().addingTimeInterval(-600)
        ) throws -> URL {
            let folder = url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            var meta = MeetingMeta(
                mode: mode,
                started: started,
                trigger: .manual,
                input: AudioInputInfo(device: "Test"),
                app: "0.1.0"
            )
            if state != .recording {
                meta.finishCapture(at: started.addingTimeInterval(60), reason: .manual)
                try meta.transition(to: .transcribing)
                if state == .done { try meta.transition(to: .done) }
                if state == .failed { try meta.fail(reason: "for the test") }
            }
            try meta.jsonData().write(to: folder.appendingPathComponent("meta.json"))

            try audio.write(into: folder, channels: mode.channels.count)
            if !indexLines.isEmpty {
                try Data(indexLines.joined().utf8)
                    .write(to: folder.appendingPathComponent(ScreensIndexWriter.fileName))
            }
            if let lock { MeetingLock.write(lock, in: folder) }
            return folder
        }

        func meta(of folder: URL) throws -> MeetingMeta {
            try MeetingMeta.decode(
                from: try Data(contentsOf: folder.appendingPathComponent("meta.json"))
            )
        }
    }

    /// What `audio.wav` should look like when the scan finds it.
    enum AudioFixture {
        /// No file at all.
        case none
        /// A header and nothing else — a recording that died before the first buffer.
        case headerOnly
        /// A header claiming zero bytes, followed by `seconds` of real samples. Exactly
        /// what an `AVAudioFile` that was never closed leaves behind.
        case staleHeader(seconds: Double)

        func write(into folder: URL, channels: Int) throws {
            let url = folder.appendingPathComponent(WAVWriter.fileName)
            let sampleRate: UInt32 = 48_000
            let bytesPerFrame = channels * 2
            let header = WAVHeader.canonicalPCMHeader(
                channelCount: UInt16(channels),
                sampleRate: sampleRate,
                bitsPerSample: 16,
                // Zero, both of them: what a header written at the start of a recording
                // and never revisited says.
                dataSize: 0,
                riffSize: 36
            )
            switch self {
            case .none:
                return
            case .headerOnly:
                try Data(header).write(to: url)
            case .staleHeader(let seconds):
                var data = Data(header)
                let frames = Int(Double(sampleRate) * seconds)
                data.append(Data(repeating: 0x11, count: frames * bytesPerFrame))
                try data.write(to: url)
            }
        }
    }

    private static func makeRoot() -> Root {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let suiteName = "de.21m.steno.tests.recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let queueStore = TranscriptionQueueStore(defaults: defaults)
        return Root(
            url: url,
            suiteName: suiteName,
            defaults: defaults,
            queueStore: queueStore,
            scanner: RecoveryScanner(store: RecordingStore(), queueStore: queueStore)
        )
    }

    /// Runs a scan and collects what it handed over.
    @discardableResult
    private static func scan(_ root: Root, enqueued: inout [URL]) -> RecoveryScanner.Report {
        var collected: [URL] = []
        let report = root.scanner.scan(root: root.url) { collected.append($0) }
        enqueued = collected
        return report
    }

    /// Makes everything in a folder look old enough for the ten-second rule.
    private static func age(_ folder: URL, by seconds: TimeInterval = 60) throws {
        let when = Date().addingTimeInterval(-seconds)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.stenoPath)
        for name in contents {
            try FileManager.default.setAttributes(
                [.modificationDate: when],
                ofItemAtPath: folder.appendingPathComponent(name).stenoPath
            )
        }
    }

    private static let sampleLine = ScreensIndexEntry(
        t: 1.5,
        at: Date(timeIntervalSince1970: 1_788_957_013),
        file: "screens/000001_d0.jpg",
        display: 0,
        active: false,
        changed: 0.4
    ).jsonLine() + "\n"

    // MARK: - recording

    @Test("a crash mid-recording is repaired, finished, and queued")
    func finishesAnInterruptedRecording() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .recording,
            audio: .staleHeader(seconds: 12),
            indexLines: [Self.sampleLine, Self.sampleLine],
            lock: MeetingLock(pid: 999_999, processStarted: Date(), app: "0.1.0")
        )
        try Self.age(folder)

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)

        #expect(report.recovered == 1)
        #expect(report.headersRepaired == 1)
        #expect(enqueued.map(\.resolvedPath) == [folder.resolvedPath])

        let meta = try root.meta(of: folder)
        #expect(meta.state == .transcribing)
        #expect(meta.stopReason == .crash)
        #expect(meta.ended != nil)
        #expect(meta.duration != nil)
        #expect(meta.screenshots == 2)
        #expect(meta.audio == "audio.wav")

        // The header now describes the file, and AVFoundation — which is what
        // transcription opens it with — agrees about the length.
        let audio = folder.appendingPathComponent(WAVWriter.fileName)
        let data = try Data(contentsOf: audio)
        let header = try WAVHeader.parse(data)
        #expect(header.validate(fileSize: data.count).isValid)
        #expect(abs(header.validate(fileSize: data.count).duration - 12) < 0.01)
        let reopened = try AVAudioFile(forReading: audio)
        #expect(reopened.length == 12 * 48_000)

        // And the claim on the folder is gone.
        #expect(!FileManager.default.fileExists(atPath: MeetingLock.url(in: folder).stenoPath))
    }

    @Test("a two-channel recording is repaired to the right length")
    func repairsStereo() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Teams",
            state: .recording,
            mode: .online,
            audio: .staleHeader(seconds: 5)
        )
        try Self.age(folder)

        var enqueued: [URL] = []
        #expect(Self.scan(root, enqueued: &enqueued).recovered == 1)

        let audio = folder.appendingPathComponent(WAVWriter.fileName)
        let reopened = try AVAudioFile(forReading: audio)
        #expect(reopened.fileFormat.channelCount == 2)
        #expect(reopened.length == 5 * 48_000)
    }

    @Test("a header that is already right is left as it is")
    func doesNotRewriteAValidHeader() throws {
        // What the periodic refresh in `WAVWriter` leaves behind: the sizes are already
        // correct when the scan arrives, so there is nothing to repair.
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .recording,
            audio: .staleHeader(seconds: 3)
        )
        let audio = folder.appendingPathComponent(WAVWriter.fileName)
        let data = try Data(contentsOf: audio)
        try Data(try WAVHeader.parse(data).repairedHeader(fileSize: data.count) + data.dropFirst(44))
            .write(to: audio)
        try Self.age(folder)

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)
        #expect(report.recovered == 1)
        #expect(report.headersRepaired == 0)
        #expect(try root.meta(of: folder).state == .transcribing)
    }

    @Test("a recording that captured nothing is marked failed, not queued")
    func failsWithoutAudio() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let empty = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .recording,
            audio: .headerOnly
        )
        let missing = try root.makeMeeting(
            named: "2026-09-09_1500_Vorort",
            state: .recording,
            audio: .none
        )
        try Self.age(empty)
        try Self.age(missing)

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)

        #expect(report.failed == 2)
        #expect(enqueued.isEmpty)
        for folder in [empty, missing] {
            let meta = try root.meta(of: folder)
            #expect(meta.state == .failed)
            #expect(meta.error == RecoveryScanner.noAudioReason)
            // It still says what it was, rather than nothing at all.
            #expect(meta.stopReason == .crash)
            #expect(meta.duration != nil)
        }
    }

    @Test("a half-written last line of screens.jsonl is cut off")
    func trimsTheIndex() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .recording,
            audio: .staleHeader(seconds: 2),
            indexLines: [Self.sampleLine, Self.sampleLine, "{\"t\":9.1,\"file\":\"scre"]
        )
        try Self.age(folder)

        var enqueued: [URL] = []
        #expect(Self.scan(root, enqueued: &enqueued).recovered == 1)

        let index = folder.appendingPathComponent(ScreensIndexWriter.fileName)
        let text = try String(contentsOf: index, encoding: .utf8)
        // Strictly, not leniently: the file has to be readable by anything now.
        #expect(try ScreensIndexEntry.decode(jsonl: text).count == 2)
        #expect(!text.contains("scre\""))
        #expect(try root.meta(of: folder).screenshots == 2)
    }

    // MARK: - The folders it must not touch

    @Test("a folder locked by a live process is left completely alone")
    func skipsALiveLock() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        // This process is alive by definition, which is the only PID a test can be
        // sure of.
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .recording,
            audio: .staleHeader(seconds: 4),
            lock: .current(app: "0.1.0")
        )
        try Self.age(folder)

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)

        #expect(report.skipped == 1)
        #expect(report.didAnything == false)
        #expect(enqueued.isEmpty)
        #expect(try root.meta(of: folder).state == .recording)
        // Not even the header: a file still being appended to is not ours to rewrite.
        let data = try Data(contentsOf: folder.appendingPathComponent(WAVWriter.fileName))
        #expect(try WAVHeader.parse(data).declaredDataSize == 0)
        #expect(FileManager.default.fileExists(atPath: MeetingLock.url(in: folder).stenoPath))
    }

    @Test("a folder written seconds ago is left alone whether it is locked or not")
    func skipsAYoungFolder() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .recording,
            audio: .staleHeader(seconds: 4)
        )
        // Deliberately not aged: everything in it was written just now.

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)

        #expect(report.skipped == 1)
        #expect(enqueued.isEmpty)
        #expect(try root.meta(of: folder).state == .recording)
    }

    @Test("a failed folder is left alone for the manual retry")
    func leavesFailedAlone() throws {
        // The disk-full case: `WAVWriter.onError` ended the recording and the
        // coordinator wrote `failed`. Re-queueing it here would retry a write on a
        // volume that is still full, three times, on every launch.
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .failed,
            audio: .staleHeader(seconds: 4)
        )
        try Self.age(folder)
        let before = try root.meta(of: folder)

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)

        #expect(report.skipped == 1)
        #expect(report.didAnything == false)
        #expect(enqueued.isEmpty)
        #expect(try root.meta(of: folder) == before)
    }

    @Test("a done folder is left alone")
    func leavesDoneAlone() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .done,
            audio: .staleHeader(seconds: 4)
        )
        try Self.age(folder)
        let before = try root.meta(of: folder)

        var enqueued: [URL] = []
        #expect(Self.scan(root, enqueued: &enqueued).skipped == 1)
        #expect(enqueued.isEmpty)
        #expect(try root.meta(of: folder) == before)
    }

    @Test("a folder that is not Steno's is not a meeting")
    func ignoresForeignFolders() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let notes = root.url.appendingPathComponent("Notizen", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: notes.appendingPathComponent("meta.json"))

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)
        #expect(report == RecoveryScanner.Report())
    }

    // MARK: - transcribing

    @Test("a transcribing folder the queue has forgotten is queued again")
    func requeuesAForgottenFolder() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .transcribing,
            audio: .staleHeader(seconds: 4)
        )
        try Self.age(folder)

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)

        #expect(report.requeued == 1)
        #expect(enqueued.map(\.resolvedPath) == [folder.resolvedPath])
        // Untouched otherwise: it has already been finished once.
        #expect(try root.meta(of: folder).state == .transcribing)
        #expect(try root.meta(of: folder).stopReason == .manual)
    }

    @Test("a transcribing folder the queue still has is left to the queue")
    func leavesQueuedFoldersToTheQueue() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .transcribing,
            audio: .staleHeader(seconds: 4)
        )
        try Self.age(folder)
        var queue = TranscriptionQueueState()
        queue.enqueue(folder.standardizedFileURL.stenoPath)
        root.queueStore.save(queue)

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)

        #expect(report.skipped == 1)
        #expect(enqueued.isEmpty)
    }

    @Test("a folder that has used up its attempts is failed and dropped from the queue")
    func givesUpAfterThreeAttempts() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .transcribing,
            audio: .staleHeader(seconds: 4)
        )
        try Self.age(folder)
        let path = folder.standardizedFileURL.stenoPath
        root.queueStore.save(
            TranscriptionQueueState(
                entries: [
                    .init(path: path, attempts: TranscriptionQueueState.maxAttempts)
                ]
            )
        )

        var enqueued: [URL] = []
        let report = Self.scan(root, enqueued: &enqueued)

        #expect(report.failed == 1)
        #expect(enqueued.isEmpty)
        #expect(try root.meta(of: folder).state == .failed)
        #expect(try root.meta(of: folder).error == RecoveryScanner.tooManyAttemptsReason)
        #expect(root.queueStore.load().contains(path) == false)
    }

    // MARK: - The report

    @Test("the menu line counts the meetings that are being picked up")
    func reportWording() {
        #expect(RecoveryScanner.Report().localizedNotice == nil)
        #expect(RecoveryScanner.Report(recovered: 1).localizedNotice?.contains("1") == true)
        let many = RecoveryScanner.Report(recovered: 2, requeued: 1)
        #expect(many.pending == 3)
        #expect(many.localizedNotice?.contains("3") == true)
        // Nothing pending but something lost still says so.
        #expect(RecoveryScanner.Report(failed: 1).localizedNotice != nil)
        // A folder that was only skipped is not worth a word.
        #expect(RecoveryScanner.Report(skipped: 4).localizedNotice == nil)
    }

    // MARK: - MeetingLock

    @Test("a lock naming this process is alive; one naming a dead process is not")
    func lockLiveness() {
        let mine = MeetingLock.current(app: "0.1.0")
        #expect(mine.pid == getpid())
        #expect(mine.isAlive)
        #expect(mine.status == .ours(pid: getpid()))

        // A PID that cannot exist.
        let dead = MeetingLock(pid: 999_999, processStarted: Date(), app: "0.1.0")
        #expect(!dead.isAlive)
        #expect(dead.status == .stale(pid: 999_999))
    }

    @Test("a reused PID is not the process the lock named")
    func lockSurvivesPIDReuse() {
        // Same PID, a start time that is not this process's: what a stale lock looks
        // like after a reboot handed the number to somebody else.
        let impostor = MeetingLock(
            pid: getpid(),
            processStarted: Date(timeIntervalSince1970: 1),
            app: "0.1.0"
        )
        #expect(!impostor.isAlive)
        #expect(impostor.status == .stale(pid: getpid()))
    }

    @Test("a lock is written, read back, and removed")
    func lockRoundTrip() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(named: "2026-09-09_1430_Vorort", state: .recording)

        MeetingLock.write(.current(app: "0.1.0"), in: folder)
        #expect(MeetingLock.read(in: folder)?.pid == getpid())
        #expect(MeetingLock.status(in: folder).isHeld)

        MeetingLock.remove(in: folder)
        #expect(MeetingLock.read(in: folder) == nil)
        #expect(MeetingLock.status(in: folder) == .absent)
        // Twice is fine.
        MeetingLock.remove(in: folder)
    }

    @Test("an unreadable lock is no lock, so a folder cannot be stranded by one")
    func unreadableLock() throws {
        let root = Self.makeRoot()
        defer { root.tearDown() }
        let folder = try root.makeMeeting(
            named: "2026-09-09_1430_Vorort",
            state: .recording,
            audio: .staleHeader(seconds: 3)
        )
        try Data("not json".utf8).write(to: MeetingLock.url(in: folder))
        try Self.age(folder)

        #expect(MeetingLock.status(in: folder) == .absent)
        var enqueued: [URL] = []
        #expect(Self.scan(root, enqueued: &enqueued).recovered == 1)
    }

}

private extension URL {
    /// The path with every symlink resolved.
    ///
    /// `/var` is a symlink to `/private/var`, so the temporary folder a test makes and
    /// the one the scanner hands back are the same folder under two spellings, and only
    /// this comparison says so.
    var resolvedPath: String { resolvingSymlinksInPath().stenoPath }
}
