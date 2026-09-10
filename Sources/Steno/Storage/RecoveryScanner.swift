import Foundation
import StenoCore

/// Finishes, at launch, what the last run did not.
///
/// Specification §6: `state` is rewritten on every change "damit ein Absturz erkennbar
/// ist und der Ordner beim nächsten Start weiterverarbeitet werden kann". §10's M6 is
/// the other half of that sentence — a crash during a recording must leave a folder the
/// next launch recognizes and finishes. This is that pass.
///
/// It runs once, after the environment is wired and before detection starts, over one
/// level of the recording root:
///
/// | `meta.state`  | what happens |
/// |---|---|
/// | `recording`   | the app died mid-recording. `audio.wav`'s header is repaired from the file length, a half-written last line of `screens.jsonl` is cut off, `ended` comes from the newest file's modification time, `stopReason` becomes `crash`, and the folder moves to `transcribing` and is queued. |
/// | `recording`, no audio | nothing was captured. `failed`, with a reason saying so. |
/// | `transcribing` | queued again, unless the queue already has it, unless it has used up its three attempts — then `failed`. |
/// | `failed`      | left alone. The menu offers "Letztes Meeting erneut verarbeiten". |
/// | `done`        | left alone. |
///
/// Two things stop it touching a folder somebody else owns, which matters because a Mac
/// can have two Stenos on it: a `.steno-lock` whose process is alive, and a folder whose
/// newest file is less than ten seconds old. The decision itself is
/// `StenoCore.RecoveryPolicy`, where it is a table with a test rather than a sequence of
/// file-system calls.
@MainActor
struct RecoveryScanner {
    /// The reason written into `meta.error` for a recording that captured nothing.
    static var noAudioReason: String {
        String(localized: "Aufnahme abgebrochen, kein Audio")
    }

    /// The reason written when a folder has used up its transcription attempts.
    static var tooManyAttemptsReason: String {
        String(localized: "Die Verarbeitung ist dreimal fehlgeschlagen und wurde aufgegeben.")
    }

    /// What one pass did.
    struct Report: Sendable, Equatable {
        /// Interrupted recordings finished and handed to the queue.
        var recovered = 0
        /// Folders whose WAV header actually had to be rewritten. A subset of
        /// `recovered`: with the periodic header refresh (`WAVWriter`) the header is
        /// often already right, and then nothing is written.
        var headersRepaired = 0
        /// `transcribing` folders the queue had forgotten.
        var requeued = 0
        /// Folders marked `failed` — nothing captured, or out of attempts.
        var failed = 0
        /// Folders left alone, for any reason.
        var skipped = 0

        /// Folders that came out of this pass with work owed on them. What the menu
        /// line counts.
        var pending: Int { recovered + requeued }

        var didAnything: Bool {
            recovered + requeued + failed > 0
        }

        /// "1 unterbrochenes Meeting wird nachverarbeitet", for the menu.
        ///
        /// `nil` when there is nothing to say, which is every ordinary launch.
        var localizedNotice: String? {
            guard pending > 0 else {
                guard failed > 0 else { return nil }
                return failed == 1
                    ? String(localized: "1 unterbrochenes Meeting konnte nicht gerettet werden.")
                    : String(
                        format: String(localized: "%d unterbrochene Meetings konnten nicht gerettet werden."),
                        failed
                    )
            }
            return pending == 1
                ? String(localized: "1 unterbrochenes Meeting wird nachverarbeitet")
                : String(
                    format: String(localized: "%d unterbrochene Meetings werden nachverarbeitet"),
                    pending
                )
        }

        /// One line for the log. Not localized — this is a log line, not an interface.
        var logDescription: String {
            """
            \(recovered) recovered (\(headersRepaired) header(s) repaired), \
            \(requeued) requeued, \(failed) failed, \(skipped) skipped
            """
        }
    }

    private let store: RecordingStore
    private let queueStore: TranscriptionQueueStore
    private let fileManager: FileManager

    init(
        store: RecordingStore,
        queueStore: TranscriptionQueueStore,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.queueStore = queueStore
        self.fileManager = fileManager
    }

    /// Scans `root` and acts on everything it finds.
    ///
    /// - Parameter enqueue: how a folder is handed over. `TranscriptionQueue.enqueue`
    ///   in the app; a recording closure in the tests.
    /// - Returns: what it did, for the menu and the log.
    @discardableResult
    func scan(root: URL, enqueue: (URL) -> Void) -> Report {
        var report = Report()
        let folders = store.meetingFolders(in: root)
        guard !folders.isEmpty else { return report }

        let queue = queueStore.load()
        Log.storage.info(
            "recovery scan: \(folders.count, privacy: .public) folder(s) in \(root.stenoPath, privacy: .public)"
        )

        for folder in folders {
            guard let session = try? RecordingSession(existing: folder) else {
                Log.storage.notice(
                    "recovery: \(folder.lastPathComponent, privacy: .public) has an unreadable meta.json; left alone"
                )
                report.skipped += 1
                continue
            }

            let path = folder.standardizedFileURL.stenoPath
            let audio = folder.appendingPathComponent(WAVWriter.fileName)
            let audioSize = size(of: audio)
            let input = RecoveryInput(
                state: session.meta.state,
                age: Date().timeIntervalSince(newestModification(in: folder) ?? Date.distantPast),
                lock: MeetingLock.status(in: folder),
                hasAudio: audioSize != nil,
                audioFrameCount: audioSize.map { frameCount(of: audio, size: $0) } ?? 0,
                isQueued: queue.contains(path),
                attempts: queue.entries.first { $0.path == path }?.attempts ?? 0
            )

            act(RecoveryPolicy.decide(input), on: session, enqueue: enqueue, into: &report)
        }

        Log.storage.notice("recovery scan finished: \(report.logDescription, privacy: .public)")
        return report
    }

    // MARK: - Acting

    private func act(
        _ decision: RecoveryDecision,
        on session: RecordingSession,
        enqueue: (URL) -> Void,
        into report: inout Report
    ) {
        let name = session.folder.lastPathComponent

        switch decision {
        case .skip(let reason):
            report.skipped += 1
            log(skip: reason, folder: name)

        case .finishInterruptedRecording:
            if finishInterrupted(session: session, into: &report) {
                report.recovered += 1
                session.releaseLock()
                enqueue(session.folder)
            } else {
                report.failed += 1
                session.releaseLock()
            }

        case .failWithoutAudio:
            Log.storage.notice(
                "recovery: \(name, privacy: .public) captured no audio; marking it failed"
            )
            finishCapture(session: session)
            session.fail(reason: Self.noAudioReason)
            session.releaseLock()
            report.failed += 1

        case .requeue:
            Log.storage.notice("recovery: \(name, privacy: .public) is transcribing; queueing it again")
            session.releaseLock()
            enqueue(session.folder)
            report.requeued += 1

        case .giveUp:
            Log.storage.error(
                "recovery: \(name, privacy: .public) has used up its attempts; marking it failed"
            )
            session.fail(reason: Self.tooManyAttemptsReason)
            session.releaseLock()
            var queue = queueStore.load()
            queue.remove(session.folder.standardizedFileURL.stenoPath)
            queueStore.save(queue)
            report.failed += 1
        }
    }

    private func log(skip reason: RecoveryDecision.Reason, folder: String) {
        switch reason {
        case .settled(let state):
            Log.storage.debug(
                "recovery: \(folder, privacy: .public) is \(state.rawValue, privacy: .public); nothing to do"
            )
        case .tooYoung(let age):
            Log.storage.notice(
                """
                recovery: \(folder, privacy: .public) was written \
                \(String(format: "%.1f", age), privacy: .public) s ago; \
                leaving it to whoever is writing it
                """
            )
        case .locked(let pid):
            Log.storage.notice(
                """
                recovery: \(folder, privacy: .public) is locked by live pid \
                \(pid, privacy: .public); leaving it alone
                """
            )
        case .alreadyQueued:
            Log.storage.debug(
                "recovery: \(folder, privacy: .public) is already in the queue"
            )
        }
    }

    /// The `recording` → `transcribing` path, step by step and logged.
    ///
    /// - Returns: whether the folder came out of it transcribable.
    private func finishInterrupted(session: RecordingSession, into report: inout Report) -> Bool {
        let folder = session.folder
        let name = folder.lastPathComponent
        Log.storage.notice("recovery: \(name, privacy: .public) was interrupted mid-recording")

        // Read before anything is written. `ended` is the newest thing in the folder,
        // which is the last moment the recording is known to have been alive — and the
        // repair below is itself a write, so asking afterwards would answer "now".
        let ended = newestModification(in: folder) ?? Date()

        // 1 — the WAV header. A file whose header still says zero bytes is a file every
        // reader refuses; the audio itself is untouched, only the two size fields.
        let audio = folder.appendingPathComponent(WAVWriter.fileName)
        let repair = repairHeader(of: audio)
        switch repair {
        case .repaired(let duration):
            report.headersRepaired += 1
            Log.storage.notice(
                """
                recovery: \(name, privacy: .public) header repaired, \
                \(String(format: "%.1f", duration), privacy: .public) s of audio
                """
            )
        case .alreadyValid(let duration):
            Log.storage.notice(
                """
                recovery: \(name, privacy: .public) header was already right, \
                \(String(format: "%.1f", duration), privacy: .public) s of audio
                """
            )
        case .unusable(let detail):
            Log.storage.error(
                "recovery: \(name, privacy: .public) has no usable audio: \(detail, privacy: .public)"
            )
            finishCapture(session: session)
            session.fail(reason: Self.noAudioReason)
            return false
        }

        // 2 — the screenshot index. At most one line can be half-written, because each
        // append is followed by a `synchronize()`.
        let screenshots = trimIndex(in: folder)

        // 3 — what `meta.json` could not say for itself. The recording may have run a
        // fraction longer than `ended` and nothing on disk can say so, which is the
        // difference `stopReason: crash` warns a reader about.
        do {
            try session.update { meta in
                meta.finishCapture(at: ended, reason: .crash)
                meta.screenshots = screenshots
                // The WAV is what is there; the queue's archive step renames it later.
                meta.audio = WAVWriter.fileName
            }
            try session.transition(to: .transcribing)
        } catch {
            Log.storage.error(
                """
                recovery: could not finish \(name, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            session.fail(reason: error.localizedDescription)
            return false
        }

        Log.storage.notice(
            """
            recovery: \(name, privacy: .public) finished as crash, \
            \(String(format: "%.0f", session.meta.duration ?? 0), privacy: .public) s, \
            \(screenshots, privacy: .public) screenshot(s); queueing it
            """
        )
        return true
    }

    /// Sets `ended`, `duration`, and `stopReason: crash` on a folder that is about to
    /// be marked `failed`, so it says what it was rather than nothing at all.
    private func finishCapture(session: RecordingSession) {
        guard session.meta.state == .recording else { return }
        let ended = newestModification(in: session.folder) ?? Date()
        try? session.update { $0.finishCapture(at: ended, reason: .crash) }
    }

    // MARK: - The WAV header

    enum HeaderRepair: Sendable, Equatable {
        /// The header was rewritten. Carries the recording's real length.
        case repaired(duration: TimeInterval)
        /// Nothing needed doing — the periodic refresh in `WAVWriter` had kept up.
        case alreadyValid(duration: TimeInterval)
        /// No audio worth keeping: missing, header-only, or unparseable.
        case unusable(String)
    }

    /// Rewrites `audio.wav`'s RIFF and `data` sizes from the file's length, in place.
    ///
    /// Only the header bytes are written, at offset 0 — the samples are never rewritten
    /// and never copied, so this costs the same on a one-minute recording and a
    /// three-hour one. The result is validated afterwards, because a repair that cannot
    /// be verified is not a repair.
    @discardableResult
    func repairHeader(of audio: URL) -> HeaderRepair {
        guard let size = size(of: audio) else { return .unusable("audio.wav is missing") }

        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: audio)
        } catch {
            return .unusable("audio.wav cannot be opened: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        let header: WAVHeader
        do {
            let leading = try handle.read(upToCount: WAVHeader.maxHeaderByteCount) ?? Data()
            header = try WAVHeader.parse(leading)
        } catch {
            return .unusable("audio.wav has no readable header: \(error)")
        }

        let validation = header.validate(fileSize: size)
        guard validation.frameCount > 0 else {
            return .unusable("audio.wav holds \(size) byte(s), which is header and nothing else")
        }
        guard validation.needsRepair else {
            return .alreadyValid(duration: validation.duration)
        }

        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header.repairedHeaderData(fileSize: size))
            try handle.synchronize()
        } catch {
            return .unusable("audio.wav header could not be written: \(error.localizedDescription)")
        }

        // Read it back. The header is the only thing standing between an hour of audio
        // and a file nothing will open, so "we wrote it" is not good enough.
        do {
            try handle.seek(toOffset: 0)
            let leading = try handle.read(upToCount: WAVHeader.maxHeaderByteCount) ?? Data()
            let after = try WAVHeader.parse(leading).validate(fileSize: size)
            guard after.isValid else {
                return .unusable("the repaired header still disagrees: \(after.problems)")
            }
            return .repaired(duration: after.duration)
        } catch {
            return .unusable("the repaired header does not parse: \(error)")
        }
    }

    // MARK: - The screenshot index

    /// Cuts a half-written final line off `screens.jsonl` and counts what is left.
    ///
    /// - Returns: the number of complete lines, for `meta.screenshots`.
    @discardableResult
    func trimIndex(in folder: URL) -> Int {
        let url = folder.appendingPathComponent(ScreensIndexWriter.fileName)
        guard let data = try? Data(contentsOf: url) else { return 0 }

        let complete = ScreensIndexEntry.completeByteCount(ofJSONL: data)
        if complete != data.count {
            do {
                try data.prefix(complete).write(to: url, options: .atomic)
                Log.storage.notice(
                    """
                    recovery: cut \(data.count - complete, privacy: .public) half-written byte(s) \
                    off \(ScreensIndexWriter.fileName, privacy: .public)
                    """
                )
            } catch {
                Log.storage.error(
                    """
                    recovery: could not trim \(ScreensIndexWriter.fileName, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }

        let text = String(decoding: data.prefix(complete), as: UTF8.self)
        return (try? ScreensIndexEntry.decode(jsonl: text).count) ?? 0
    }

    // MARK: - File system

    private func size(of url: URL) -> Int? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        else { return nil }
        return size
    }

    private func frameCount(of audio: URL, size: Int) -> Int {
        guard
            let handle = try? FileHandle(forReadingFrom: audio),
            let leading = try? handle.read(upToCount: WAVHeader.maxHeaderByteCount),
            let header = try? WAVHeader.parse(leading)
        else { return 0 }
        try? handle.close()
        return header.validate(fileSize: size).frameCount
    }

    /// The newest modification time among the files a recording writes.
    ///
    /// `audio.wav`, `screens.jsonl`, and `meta.json`: the three things that are appended
    /// to while a recording runs, so the newest of them is the last moment the recording
    /// is known to have been alive. The folder's own modification time will not do — it
    /// changes when a file is created, not when one grows.
    func newestModification(in folder: URL) -> Date? {
        let candidates = [
            WAVWriter.fileName,
            ScreensIndexWriter.fileName,
            RecordingStore.metaFileName
        ]
        return candidates
            .map { folder.appendingPathComponent($0) }
            .compactMap { url -> Date? in
                try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            }
            .max()
    }
}
