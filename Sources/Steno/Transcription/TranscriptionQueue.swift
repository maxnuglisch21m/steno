import AppKit
import FluidAudio
import Foundation
import Observation
import StenoCore

/// What the recording coordinator hands a finished folder to.
///
/// A protocol rather than the class itself so the coordinator can be built and tested
/// without models, a queue, or a two-gigabyte checkpoint on disk.
@MainActor
protocol TranscriptionEnqueuing: AnyObject {
    /// Takes over a folder whose `meta.json` already says `transcribing`.
    func enqueue(_ folder: URL)
}

/// Specification §5, end to end: one meeting at a time, in the background, with the
/// progress in the menu bar.
///
/// ```
/// state: transcribing
///   → ChannelSplitter        audio.wav      → _work/room16k.wav [, _work/mic16k.wav]
///   → FluidASR   .system     room16k.wav    → words
///   → FluidASR   .microphone mic16k.wav     → words            (online only)
///   → FluidDiarizer          room16k.wav    → segments
///   → TranscriptMerger                      → transcript.json + transcript.md
///   → AudioTranscoder        audio.wav      → audio.m4a | audio.flac | kept
///   → meta.json: models, audio, state: done → notification
///   → rm -r _work
/// ```
///
/// Serial on purpose. Two meetings transcribed at once would fight over the Neural
/// Engine and finish later than one after the other, and the progress ring can only
/// tell one story at a time.
///
/// The queue is written down (`TranscriptionQueueState`), so a quit or a crash in the
/// middle of an hour of audio does not lose the folder: it is picked up again on the
/// next launch.
@MainActor
@Observable
final class TranscriptionQueue: TranscriptionEnqueuing {
    /// The four steps the menu bar counts through.
    ///
    /// Each owns a share of the ring. The shares are guesses at the shape of the work,
    /// not measurements — recognition dominates everything else by an order of
    /// magnitude, so it gets most of the ring and the rest are there to show that
    /// something is still happening.
    enum Step: Int, CaseIterable, Sendable {
        case channels = 1
        case speech
        case speakers
        case archive

        static let count = Step.allCases.count

        var range: ClosedRange<Double> {
            switch self {
            case .channels: return 0.00...0.05
            case .speech: return 0.05...0.65
            case .speakers: return 0.65...0.90
            case .archive: return 0.90...1.00
            }
        }

        var localizedName: String {
            switch self {
            case .channels: return String(localized: "Kanäle")
            case .speech: return String(localized: "Sprache")
            case .speakers: return String(localized: "Sprecher")
            case .archive: return String(localized: "Archiv")
            }
        }

        /// "Transkription 3/4 · Sprecher"
        var localizedLabel: String {
            String(
                format: String(localized: "Transkription %d/%d · %@"),
                rawValue,
                Self.count,
                localizedName
            )
        }
    }

    enum Failure: LocalizedError, CustomStringConvertible {
        case metaUnreadable(String)
        case notTranscribable(MeetingState)
        case noAudio
        case tooManyAttempts
        /// The models are not on this Mac. Not a failure of the meeting: the queue
        /// waits rather than marking anything `failed`, and no attempt is counted.
        case modelsUnavailable

        var description: String {
            switch self {
            case .metaUnreadable(let detail): return "meta.json is unreadable: \(detail)"
            case .notTranscribable(let state): return "the folder is \(state.rawValue), not transcribing"
            case .noAudio: return "the folder holds no audio.wav"
            case .tooManyAttempts: return "transcription failed three times"
            case .modelsUnavailable: return "the transcription models are not installed"
            }
        }

        var errorDescription: String? {
            switch self {
            case .metaUnreadable:
                return String(localized: "Die meta.json des Meetings ist unlesbar.")
            case .notTranscribable:
                return String(localized: "Dieses Meeting ist nicht zur Verarbeitung vorgemerkt.")
            case .noAudio:
                return String(localized: "Zu diesem Meeting gibt es keine Audiodatei.")
            case .tooManyAttempts:
                return String(localized: "Die Verarbeitung ist dreimal fehlgeschlagen und wurde aufgegeben.")
            case .modelsUnavailable:
                return String(localized: "Die Modelle fehlen noch. Die Verarbeitung wartet.")
            }
        }
    }

    private let appState: AppState
    private let settings: SettingsStore
    private let models: ModelManager
    private let store: TranscriptionQueueStore

    /// The folder being worked on, for the menu and for the tests.
    private(set) var current: URL?
    /// How many folders are waiting, the running one included.
    private(set) var pendingCount = 0

    private var runner: Task<Void, Never>?

    init(
        appState: AppState,
        settings: SettingsStore,
        models: ModelManager,
        store: TranscriptionQueueStore
    ) {
        self.appState = appState
        self.settings = settings
        self.models = models
        self.store = store
        pendingCount = store.load().count
    }

    // MARK: - Taking work

    /// Queues a folder and starts working if nothing is running.
    func enqueue(_ folder: URL) {
        var state = store.load()
        if state.enqueue(folder.standardizedFileURL.stenoPath) {
            store.save(state)
            Log.transcription.notice(
                "queued \(folder.lastPathComponent, privacy: .public) for transcription"
            )
        }
        pendingCount = state.count
        run()
    }

    /// "Letztes Meeting erneut verarbeiten": moves a `failed` folder back to
    /// `transcribing` and queues it.
    ///
    /// The one path that resets the attempt count, because a person asking for it again
    /// is not the same as the app retrying by itself.
    func reprocess(_ folder: URL) {
        do {
            let session = try RecordingSession(existing: folder)
            switch session.meta.state {
            case .failed:
                try session.transition(to: .transcribing)
            case .transcribing:
                break
            case .done, .recording:
                Log.transcription.notice(
                    "refusing to reprocess \(folder.lastPathComponent, privacy: .public): it is \(session.meta.state.rawValue, privacy: .public)"
                )
                appState.notice = Failure.notTranscribable(session.meta.state).localizedDescription
                return
            }
        } catch {
            Log.transcription.error(
                "could not reopen \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            appState.notice = error.localizedDescription
            return
        }
        var state = store.load()
        state.remove(folder.standardizedFileURL.stenoPath)
        store.save(state)
        enqueue(folder)
    }

    /// Picks up whatever the last launch did not finish.
    ///
    /// M6 adds the full recovery scan of the recording root; this is the half that
    /// belongs to the queue — the folders it was already told about.
    func resumePersisted() {
        var state = store.load()
        state.removeMissing { FileManager.default.fileExists(atPath: $0) }
        store.save(state)
        pendingCount = state.count
        guard !state.isEmpty else { return }
        Log.transcription.notice(
            "\(state.count, privacy: .public) meeting(s) left over from the last launch"
        )
        run()
    }

    // MARK: - The loop

    private func run() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                let hasMore = await self.workOnce()
                if !hasMore { break }
            }
            self?.runner = nil
        }
    }

    /// Works one folder. Returns whether there might be another.
    private func workOnce() async -> Bool {
        var state = store.load()
        guard let entry = state.head else {
            store.save(state)
            pendingCount = 0
            current = nil
            // Only the phase this queue put there. A recording that started in the
            // meantime owns the menu bar, and an empty queue is no reason to say it
            // is idle.
            if appState.phase.isProcessing { appState.phase = .idle }
            return false
        }

        let folder = URL(fileURLWithPath: entry.path, isDirectory: true)
        guard let begun = state.beginHead() else {
            // Out of attempts: mark it failed and move on rather than relaunching into
            // it for ever.
            store.save(state)
            pendingCount = state.count
            fail(folder: folder, with: Failure.tooManyAttempts)
            return true
        }
        store.save(state)

        current = folder
        pendingCount = state.count
        appState.phase = .processing(progress: 0, label: Step.channels.localizedLabel)
        Log.transcription.notice(
            "transcribing \(folder.lastPathComponent, privacy: .public) (attempt \(begun.attempts, privacy: .public))"
        )

        do {
            try await process(folder)
            finished(folder: folder)
        } catch is CancellationError {
            // A quit during transcription leaves `state: transcribing`, which is
            // exactly what the next launch looks for.
            Log.transcription.notice("transcription cancelled; the folder stays queued")
            current = nil
            return false
        } catch Failure.modelsUnavailable {
            // Not this folder's fault, so not this folder's attempt. The queue stands
            // down with the folder still queued and picks it up when the models arrive.
            Log.transcription.notice(
                "the models are not on this Mac yet; the queue stands down and keeps the folder"
            )
            var waiting = store.load()
            waiting.refundHead(entry.path)
            store.save(waiting)
            pendingCount = waiting.count
            current = nil
            appState.notice = String(localized: "Die Modelle fehlen noch. Die Verarbeitung wartet.")
            if appState.phase.isProcessing { appState.phase = .idle }
            waitForModels()
            return false
        } catch {
            fail(folder: folder, with: error)
        }

        var after = store.load()
        after.remove(entry.path)
        store.save(after)
        pendingCount = after.count
        current = nil
        return true
    }

    // MARK: - Waiting for the models

    /// Set while an observation of `ModelManager` is armed, so only one ever is.
    private var isWaitingForModels = false

    /// Re-arms the queue for the moment the models arrive.
    ///
    /// The download runs from the onboarding window or the settings, which are
    /// somewhere else entirely; `withObservationTracking` fires once, so this re-arms
    /// itself until the state it is waiting for actually appears.
    private func waitForModels() {
        guard !isWaitingForModels else { return }
        isWaitingForModels = true
        withObservationTracking {
            _ = models.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isWaitingForModels = false
                guard !self.store.load().isEmpty else { return }
                if self.models.isInstalled {
                    Log.transcription.notice("the models arrived; picking the queue up again")
                    self.appState.notice = nil
                    self.run()
                } else {
                    self.waitForModels()
                }
            }
        }
    }

    // MARK: - One meeting

    private func process(_ folder: URL) async throws {
        let session = try openForTranscription(folder)
        let meta = session.meta
        let audio = folder.appendingPathComponent(WAVWriter.fileName)
        guard FileManager.default.fileExists(atPath: audio.stenoPath) else {
            throw Failure.noAudio
        }

        // The models, loaded once per launch. Downloading is a no-op when they are
        // already on disk, which is what makes this safe to call per meeting.
        //
        // A failure here is not a failure of this meeting — no models on the Mac yet, no
        // network to fetch them over — so it is thrown as its own case, which the queue
        // above turns into waiting rather than into `state: failed`. Without that, a
        // recovery at launch on a Mac whose download has not happened would use up all
        // three of the folder's attempts before anyone could do anything about it.
        do {
            try await models.prepare(warm: false)
        } catch {
            Log.transcription.notice(
                "the models could not be prepared: \(error.localizedDescription, privacy: .public)"
            )
            throw Failure.modelsUnavailable
        }
        let identifiers = models.modelIdentifiers

        // 1 — channels.
        report(.channels, 0)
        let wantsMic = meta.mode.supportsSelfSpeaker
        let split = try await Task.detached(priority: .utility) {
            try ChannelSplitter.split(audio: audio, in: folder, wantsMic: wantsMic)
        }.value
        try Task.checkCancellation()

        // 2 — speech. Two passes for `online`, one for `onsite`; the microphone pass is
        // short next to the room pass, so the room gets three quarters of the step.
        report(.speech, 0)
        let language = settings.settings.transcriptionLanguage.languageCode
        let roomPass = try await models.asr.transcribe(
            split.room,
            source: .system,
            language: language,
            progress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.report(.speech, split.mic == nil ? fraction : fraction * 0.75)
                }
            }
        )
        try Task.checkCancellation()

        var micPass: ASRPass?
        if let mic = split.mic {
            report(.speech, 0.75)
            micPass = try await models.asr.transcribe(
                mic,
                source: .microphone,
                language: language,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.report(.speech, 0.75 + fraction * 0.25)
                    }
                }
            )
            try Task.checkCancellation()
        }

        // 3 — speakers. Channel 0 in both modes: the room microphone for `onsite`, the
        // tapped meeting audio for `online`.
        report(.speakers, 0)
        let bounds = FluidDiarizer.SpeakerBounds(expected: meta.speakers?.expected)
        let segments = try await models.diarizer.diarize(
            split.room,
            bounds: bounds,
            progress: { [weak self] fraction in
                Task { @MainActor [weak self] in self?.report(.speakers, fraction) }
            }
        )
        try Task.checkCancellation()

        // The merge itself — specification §5, and the one step with no model in it.
        let transcript = TranscriptMerger.merge(
            mode: meta.mode,
            roomTokens: roomPass.tokens,
            micTokens: micPass?.tokens,
            diarization: segments,
            models: identifiers
        )
        // The recognizer's own per-pass confidence is a better number than the mean of
        // the token confidences the merger computes, so it replaces it. `asr_mic` stays
        // an explicit null wherever there was no microphone channel.
        var written = transcript
        written.confidence = Transcript.Confidence(
            asrRoom: roomPass.confidence,
            asrMic: meta.mode.supportsSelfSpeaker ? micPass?.confidence : nil
        )
        written = written.roundingTimes()

        try write(written, meta: meta, in: folder)

        // 4 — archive. From here on nothing may fail the meeting: the transcript is
        // already on disk, and a WAV that could not be transcoded is still a WAV.
        report(.archive, 0)
        let archive = await self.archive(audio: audio, in: folder)

        try session.update { meta in
            meta.models = identifiers
            meta.audio = archive.fileName
        }
        try session.transition(to: .done)

        report(.archive, 1)
        ChannelSplitter.removeWorkDirectory(in: folder)

        Log.transcription.notice(
            """
            \(folder.lastPathComponent, privacy: .public) done: \
            \(written.utterances.count, privacy: .public) utterance(s), \
            \(written.speakers.count, privacy: .public) speaker(s), \
            archive \(archive.fileName, privacy: .public) \
            (\(archive.bytes / 1_048_576, privacy: .public) MB)
            """
        )
        notifyDone(folder: folder, duration: meta.duration ?? split.duration)
    }

    /// Opens the folder and checks that it is one this queue may work on.
    private func openForTranscription(_ folder: URL) throws -> RecordingSession {
        let session: RecordingSession
        do {
            session = try RecordingSession(existing: folder)
        } catch {
            throw Failure.metaUnreadable(error.localizedDescription)
        }
        guard session.meta.state == .transcribing else {
            throw Failure.notTranscribable(session.meta.state)
        }
        return session
    }

    /// Writes `transcript.json` and `transcript.md`, atomically, before anything else
    /// in the folder is touched.
    private func write(_ transcript: Transcript, meta: MeetingMeta, in folder: URL) throws {
        try transcript.jsonData().write(
            to: folder.appendingPathComponent("transcript.json"),
            options: .atomic
        )
        let markdown = TranscriptMarkdownFormatter().markdown(
            for: transcript,
            started: meta.started,
            duration: meta.duration
        )
        try Data(markdown.utf8).write(
            to: folder.appendingPathComponent("transcript.md"),
            options: .atomic
        )
    }

    /// Produces the audio archive, and never throws.
    ///
    /// Specification §6 says `meta.audio` names the file that is there. A transcode
    /// that fails leaves the WAV, and that is what the field then says — the meeting is
    /// `done` either way, because the transcript is what the meeting was for.
    private func archive(audio: URL, in folder: URL) async -> AudioTranscoder.Result {
        let format = settings.settings.audioArchiveFormat
        do {
            let result = try await Task.detached(priority: .utility) {
                try await AudioTranscoder.archive(wav: audio, as: format, in: folder)
            }.value
            if let fallback = result.fallbackReason {
                Log.transcription.notice("archive fallback: \(fallback, privacy: .public)")
            }
            return result
        } catch {
            Log.transcription.error(
                "archive failed, keeping the WAV: \(String(describing: error), privacy: .public)"
            )
            return AudioTranscoder.Result(
                fileName: WAVWriter.fileName,
                channels: 0,
                duration: 0,
                bytes: AudioTranscoder.size(of: audio),
                fallbackReason: String(describing: error)
            )
        }
    }

    // MARK: - Endings

    private func finished(folder: URL) {
        appState.lastMeetingURL = folder
        appState.lastMeetingState = .done
        appState.notice = nil
    }

    /// Writes `state: failed` with a reason, tells the user, and leaves `_work/` alone.
    ///
    /// The scratch files are the inputs of the run that failed; deleting them would
    /// throw away the only thing that says why.
    private func fail(folder: URL, with error: any Error) {
        let localized = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.transcription.error(
            """
            \(folder.lastPathComponent, privacy: .public) failed: \
            \(String(describing: error), privacy: .public)
            """
        )
        if let session = try? RecordingSession(existing: folder), session.meta.state == .transcribing {
            session.fail(reason: localized)
        }
        appState.lastMeetingURL = folder
        appState.lastMeetingState = .failed
        appState.notice = localized
        notifyFailure(folder: folder, reason: localized)
    }

    // MARK: - Progress

    /// Moves the ring inside one step's share of it.
    private func report(_ step: Step, _ fraction: Double) {
        let range = step.range
        let clamped = min(max(fraction, 0), 1)
        appState.phase = .processing(
            progress: range.lowerBound + (range.upperBound - range.lowerBound) * clamped,
            label: label(for: step)
        )
    }

    /// "Transkription 3/4 · Sprecher", plus "(2 warten)" when more are queued behind.
    private func label(for step: Step) -> String {
        guard pendingCount > 1 else { return step.localizedLabel }
        return String(
            format: String(localized: "%@ (noch %d)"),
            step.localizedLabel,
            pendingCount - 1
        )
    }

    // MARK: - Notifications

    private func notifyDone(folder: URL, duration: TimeInterval) {
        let isEnabled = settings.settings.notificationsEnabled
        let minutes = max(1, Int((duration / 60).rounded()))
        let body = String(
            format: String(localized: "%@ · %d min"),
            folder.lastPathComponent,
            minutes
        )
        Task {
            await Notifications.shared.post(
                title: String(localized: "Transkript fertig"),
                body: body,
                folder: folder,
                isEnabled: isEnabled
            )
        }
    }

    private func notifyFailure(folder: URL, reason: String) {
        let isEnabled = settings.settings.notificationsEnabled
        Task {
            await Notifications.shared.post(
                title: String(localized: "Transkription fehlgeschlagen"),
                body: reason,
                folder: folder,
                isEnabled: isEnabled
            )
        }
    }

    // MARK: - Quitting

    /// Stops after the current step. The folder stays `transcribing`, which is what the
    /// next launch picks up.
    func prepareForTermination() {
        runner?.cancel()
    }
}

/// The queue, on disk.
///
/// In `UserDefaults` rather than in a file of its own: it is app state, not meeting
/// data, and specification §11.11 is about the recording root. `de.21m.steno` already
/// holds the settings blob, and one store is easier to reason about — and to clear —
/// than two.
@MainActor
final class TranscriptionQueueStore {
    static let defaultsKey = "transcriptionQueue"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> TranscriptionQueueState {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return .empty }
        do {
            return try TranscriptionQueueState.decode(from: data)
        } catch {
            Log.transcription.error(
                "transcription queue unreadable, starting empty: \(error.localizedDescription, privacy: .public)"
            )
            return .empty
        }
    }

    func save(_ state: TranscriptionQueueState) {
        guard !state.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        do {
            defaults.set(try state.jsonData(), forKey: Self.defaultsKey)
        } catch {
            Log.transcription.error(
                "could not save the transcription queue: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
