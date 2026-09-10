import CoreML
import FluidAudio
import Foundation
import StenoCore

/// pyannote community-1 plus VBx, wrapped so that FluidAudio's diarizer — which is a
/// plain class and not `Sendable` — never leaves this actor.
///
/// Specification §5 runs diarization on channel 0 in both modes: the room microphone
/// for `onsite`, the tapped system audio for `online`. Channel 1 of an `online`
/// recording is not diarized at all, because it is physically one speaker.
///
/// Two things about the API differ from the specification's pseudo-code:
///
/// - `prepareModels(directory:)` takes the **cache root**, not the repository folder:
///   it appends `speaker-diarization` itself. `AsrModels.download(to:)` takes the
///   repository folder and derives the root from its parent. The two look alike and
///   mean opposite things, which is why both callers spell it out.
/// - `process(_ url:)` exists and streams the file from disk, so an hour of room audio
///   never becomes an hour of `[Float]`. Its `progressCallback` reports
///   `(chunksProcessed, totalChunks)`, not a fraction.
actor FluidDiarizer {
    enum Failure: LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return String(localized: "Die Sprechertrennung ist nicht geladen.")
            }
        }
    }

    /// The name written to `meta.models.diarizer` and `transcript.json`.
    ///
    /// The model, not the repository: FluidAudio keeps the offline diarizer's four
    /// Core ML bundles in a repository it calls `speaker-diarization`, but what is in
    /// them is pyannote community-1, which is the name specification §5 writes and the
    /// one a reader can look up.
    static let modelIdentifier = "pyannote-community-1"

    /// Never handed out: every use goes through this actor and through `Holder`.
    private var holder: Holder?
    private var loadedDirectory: URL?
    /// The speaker bounds the loaded manager was built with. A different hint needs a
    /// different manager, because `OfflineDiarizerConfig` is fixed at construction.
    private var loadedBounds: SpeakerBounds = .automatic

    /// What the user said about how many people are in the room (specification §3b),
    /// clamped to the range the picker offers.
    struct SpeakerBounds: Sendable, Equatable {
        var minimum: Int?
        var maximum: Int?

        static let automatic = SpeakerBounds(minimum: nil, maximum: nil)

        /// An exact count from `meta.speakers.expected`, or `automatic`.
        ///
        /// The hint is fed as both bounds rather than as `numSpeakers`: it is what the
        /// user expected, not what was measured, and the two bounds leave the
        /// clustering free to place the boundaries while holding it to the count.
        init(expected: Int?) {
            guard let expected, SpeakerHint.allowedRange.contains(expected) else {
                self = .automatic
                return
            }
            minimum = expected
            maximum = expected
        }

        init(minimum: Int?, maximum: Int?) {
            self.minimum = minimum
            self.maximum = maximum
        }

        var isAutomatic: Bool { minimum == nil && maximum == nil }
    }

    var isLoaded: Bool { holder != nil }

    // MARK: - Loading

    /// Downloads what is missing, compiles, and pre-warms.
    ///
    /// - Parameter directory: the cache root — `<models>`, not `<models>/speaker-diarization`.
    func load(directory: URL, bounds: SpeakerBounds = .automatic) async throws {
        if holder != nil, loadedDirectory == directory, loadedBounds == bounds { return }
        let created = Holder(config: Self.configuration(bounds: bounds))
        // Loads, and on failure purges the repo and downloads it again. It pre-warms
        // the models itself, so nothing else has to.
        try await created.prepare(directory: directory)
        holder = created
        loadedDirectory = directory
        loadedBounds = bounds
        let hint = bounds.isAutomatic
            ? "automatic"
            : "\(bounds.minimum ?? 0)…\(bounds.maximum ?? 0)"
        Log.transcription.notice(
            """
            diarizer ready from \(directory.lastPathComponent, privacy: .public) \
            (speakers \(hint, privacy: .public))
            """
        )
    }

    func unload() {
        holder = nil
        loadedDirectory = nil
        loadedBounds = .automatic
    }

    // MARK: - Diarizing

    /// Who spoke when, on one 16 kHz mono file.
    ///
    /// - Parameters:
    ///   - url: the room work file written by `ChannelSplitter`.
    ///   - bounds: the speaker hint. A different one than the models were loaded with
    ///     rebuilds the manager, because the bound lives in the immutable config.
    ///   - progress: 0…1, derived from the chunk counts FluidAudio reports.
    func diarize(
        _ url: URL,
        bounds: SpeakerBounds = .automatic,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [DiarSegment] {
        if bounds != loadedBounds, let directory = loadedDirectory {
            holder = nil
            try await load(directory: directory, bounds: bounds)
        }
        guard let holder else { throw Failure.notLoaded }

        let started = Date()
        let result: DiarizationResult
        do {
            result = try await holder.process(url) { done, total in
                guard let progress, total > 0 else { return }
                progress(min(Double(done) / Double(total), 1))
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            // Not a failure of the meeting. A room where nobody spoke, a call that was
            // joined and left again, a channel that captured hold music — all of them
            // are recordings whose correct transcript has no speakers in it, and the
            // whole meeting must not end as `failed` because of one.
            //
            // FluidAudio throws here rather than returning nothing, so this is where
            // "no speech" becomes what it actually is: an empty result.
            Log.transcription.notice("diarization found no speech; the transcript has no speakers")
            return []
        }

        var segments: [DiarSegment] = []
        segments.reserveCapacity(result.segments.count)
        for segment in result.segments {
            segments.append(
                DiarSegment(
                    speaker: segment.speakerId,
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds)
                )
            )
        }
        // Sorted here so the merger's own sort is a no-op and the raw segments in
        // `transcript.json` read in the order the meeting happened.
        segments.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        let speakers = Set(segments.map { $0.speaker }).count
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.transcription.notice(
            """
            diarization: \(segments.count, privacy: .public) segments, \
            \(speakers, privacy: .public) speaker(s), in \(elapsed, privacy: .public) s
            """
        )
        return segments
    }

    // MARK: - Configuration

    /// The diarizer itself, in a box that may cross an isolation boundary.
    ///
    /// `OfflineDiarizerManager` is a plain class with `nonisolated(unsafe)` model
    /// storage: FluidAudio writes those once during `prepareModels` and only reads them
    /// afterwards. Its `process` is a nonisolated `async` method, which is exactly what
    /// is wanted — the Core ML work belongs off the main actor and off this actor's
    /// executor — but calling it from inside the actor would mean sending an
    /// actor-isolated, non-`Sendable` value out of it.
    ///
    /// The box states the guarantee the type cannot: it is created, prepared, and used
    /// only through `FluidDiarizer`, which is an actor, so there is never more than one
    /// call in flight.
    private final class Holder: @unchecked Sendable {
        private let manager: OfflineDiarizerManager

        init(config: OfflineDiarizerConfig) {
            manager = OfflineDiarizerManager(config: config)
        }

        func prepare(directory: URL) async throws {
            try await manager.prepareModels(directory: directory)
        }

        func process(
            _ url: URL,
            progress: (@Sendable (Int, Int) -> Void)?
        ) async throws -> DiarizationResult {
            try await manager.process(url, progressCallback: progress)
        }
    }

    /// The community preset, with the speaker hint applied to the clustering.
    ///
    /// Everything else stays at FluidAudio's own defaults. Specification §3b is
    /// explicit that the signal, not the parameters, is the lever on room audio, and
    /// tuning a diarizer against no ground truth makes it worse, not better.
    static func configuration(bounds: SpeakerBounds) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.clustering.minSpeakers = bounds.minimum
        config.clustering.maxSpeakers = bounds.maximum
        return config
    }
}
