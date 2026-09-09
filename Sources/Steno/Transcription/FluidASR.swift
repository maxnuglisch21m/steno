import AVFoundation
import CoreML
import FluidAudio
import Foundation
import StenoCore

/// What one recognition pass produced.
struct ASRPass: Sendable {
    /// The recognizer's words, already assembled out of sub-word pieces.
    var tokens: [ASRToken]
    /// The recognizer's own plain text, kept for the log and for a sanity check
    /// against the words.
    var text: String
    /// `ASRResult.confidence` — the pass's own number, not an average of the tokens'.
    var confidence: Double?
    /// Length of the audio the recognizer saw.
    var duration: TimeInterval
    /// How long recognition took, for the log.
    var processingTime: TimeInterval

    /// Times faster than real time. The one number worth logging about a pass.
    var realTimeFactor: Double? {
        guard processingTime > 0, duration > 0 else { return nil }
        return duration / processingTime
    }
}

/// Parakeet, wrapped so that nothing outside this actor touches FluidAudio's ASR types.
///
/// One instance holds the loaded models for the life of the app: loading them costs
/// seconds and the first prediction after loading costs more, so a queue that reloaded
/// per meeting would pay that on every recording.
///
/// **The real API differs from the specification's pseudo-code**, and the difference is
/// worth writing down because it looks like a missing feature and is not:
///
/// - There is no `configure(models:)`. Models are handed to `AsrManager` at
///   construction, or through `loadModels(_:)`.
/// - `transcribe(_ url:)` takes **no `source:`**. `AudioSource.microphone` / `.system`
///   exists only in FluidAudio's *streaming* API, where it selects which of two
///   long-lived decoder states a stream continues. The offline path takes the decoder
///   state directly, so what `source:` would have bought — the room pass and the
///   microphone pass not contaminating each other's linguistic context — is had here by
///   giving every pass a decoder state of its own. The parameter is kept on this
///   method because the mapping is the interesting part and losing it would make the
///   two calls look interchangeable.
/// - The URL overload streams from disk on its own for anything past
///   `config.streamingThreshold`, so an hour of audio never becomes an hour of `[Float]`.
actor FluidASR {
    enum Failure: LocalizedError {
        case notLoaded
        case audioTooShort(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return String(localized: "Die Sprachmodelle sind nicht geladen.")
            case .audioTooShort(let seconds):
                return String(
                    format: String(localized: "Die Aufnahme ist mit %.1f s zu kurz für die Spracherkennung."),
                    seconds
                )
            }
        }
    }

    /// Anything shorter than this is refused by the recognizer itself
    /// (`ASRError.invalidAudioData`), so it is caught here where the message can say so.
    static let minimumDuration: TimeInterval = 0.3

    private var models: AsrModels?
    private var manager: AsrManager?
    private var loaded: (version: ASRVersion, directory: URL)?

    var isLoaded: Bool { manager != nil }

    /// The checkpoint currently in memory, for `meta.models`.
    var loadedVersion: ASRVersion? { loaded?.version }

    // MARK: - Loading

    /// Downloads what is missing and loads the models.
    ///
    /// - Parameters:
    ///   - directory: the repository folder, i.e. `<models>/parakeet-tdt-0.6b-v3`.
    ///     `AsrModels.download(to:)` treats its argument as the repo folder and derives
    ///     the cache root from its parent, which is the opposite of what the diarizer
    ///     does with the same-looking parameter — see `FluidDiarizer`.
    ///   - progress: called from FluidAudio's own threads, at every phase change and
    ///     on byte progress.
    func load(
        directory: URL,
        version: ASRVersion,
        progress: ProgressHandler? = nil
    ) async throws {
        if let loaded, loaded.version == version, loaded.directory == directory, manager != nil {
            return
        }
        let loadedModels = try await AsrModels.downloadAndLoad(
            to: directory,
            version: version.fluidVersion,
            progressHandler: progress
        )
        let newManager = AsrManager(config: .default, models: loadedModels)
        models = loadedModels
        manager = newManager
        loaded = (version, directory)
        Log.transcription.notice(
            "ASR models loaded from \(directory.lastPathComponent, privacy: .public)"
        )
    }

    /// Runs one prediction through every model so the first real transcription is not
    /// the one that pays for compilation.
    ///
    /// The first prediction of a freshly downloaded Core ML model compiles it for this
    /// Mac's Neural Engine, which can take minutes. That happening inside the first
    /// meeting's transcription looks exactly like a hang, so it is done here, once,
    /// while the interface is saying that it is happening.
    ///
    /// - Returns: how long it took.
    @discardableResult
    func warmUp() async throws -> TimeInterval {
        guard let manager else { throw Failure.notLoaded }
        let start = Date()
        // One second of silence at the recognizer's own sample rate: long enough to
        // pass the minimum-length check, short enough to cost nothing.
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let silence = [Float](repeating: 0, count: 16_000)
        _ = try await manager.transcribe(silence, decoderState: &state)
        let elapsed = Date().timeIntervalSince(start)
        Log.transcription.notice(
            "ASR warm-up finished in \(String(format: "%.1f", elapsed), privacy: .public) s"
        )
        return elapsed
    }

    func unload() {
        manager = nil
        models = nil
        loaded = nil
    }

    // MARK: - Recognizing

    /// Recognizes one 16 kHz mono file.
    ///
    /// - Parameters:
    ///   - url: a work file written by `ChannelSplitter`.
    ///   - source: which channel this is. It does not reach FluidAudio — see the note
    ///     on this type — but it decides the log line and documents the call.
    ///   - progress: 0…1 while long audio is decoded, from `AsrManager`'s own stream.
    func transcribe(
        _ url: URL,
        source: AudioSource,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ASRPass {
        guard let manager else { throw Failure.notLoaded }

        let duration = try Self.duration(of: url)
        guard duration >= Self.minimumDuration else { throw Failure.audioTooShort(duration) }

        // A decoder state per pass. This is what `source:` buys in the streaming API:
        // the microphone pass must not continue the room pass's linguistic context.
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)

        let progressTask: Task<Void, Never>?
        if let progress {
            progressTask = Task {
                let stream = await manager.transcriptionProgressStream
                // The stream ends when the pass does and throws when the pass throws.
                // Either way the error belongs to `transcribe`, which is about to
                // throw it properly; here it only ends the reporting.
                do {
                    for try await fraction in stream {
                        if Task.isCancelled { return }
                        progress(fraction)
                    }
                } catch {
                    return
                }
            }
        } else {
            progressTask = nil
        }
        defer { progressTask?.cancel() }

        let result = try await manager.transcribe(url, decoderState: &state)
        let tokens = Self.words(from: result)

        Log.transcription.notice(
            """
            ASR \(Self.name(of: source), privacy: .public): \
            \(tokens.count, privacy: .public) words in \
            \(String(format: "%.1f", result.processingTime), privacy: .public) s \
            for \(String(format: "%.1f", result.duration), privacy: .public) s of audio \
            (confidence \(String(format: "%.2f", result.confidence), privacy: .public))
            """
        )

        return ASRPass(
            tokens: tokens,
            text: result.text,
            // `ASRResult.confidence` is 0 when the recognizer had nothing to be
            // confident about; an empty pass reports no confidence rather than none.
            confidence: tokens.isEmpty ? nil : Double(result.confidence),
            duration: result.duration,
            processingTime: result.processingTime
        )
    }

    // MARK: - Mapping

    /// `ASRResult.tokenTimings` → words, through `StenoCore.WordAssembler`.
    ///
    /// The timings are SentencePiece pieces: `"Centerplan"` arrives as `▁Center` plus
    /// `plan`. FluidAudio has a `buildWordTimings(from:)` of its own, but it drops the
    /// per-token confidence, which is the one number the merger needs to average — so
    /// the assembly happens in `StenoCore`, where it is tested without a checkpoint.
    static func words(from result: ASRResult) -> [ASRToken] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No timings at all — a very short pass can produce text and no timing. One
            // token spanning the pass is worth more than an empty transcript.
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                ASRToken(
                    text: text,
                    start: 0,
                    end: result.duration,
                    confidence: Double(result.confidence)
                )
            ]
        }
        return WordAssembler.words(
            from: timings.map {
                SubwordPiece(
                    text: $0.token,
                    start: $0.startTime,
                    end: $0.endTime,
                    confidence: Double($0.confidence)
                )
            }
        )
    }

    /// Length of an audio file, without decoding it.
    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func name(of source: AudioSource) -> String {
        switch source {
        case .microphone: return "mic"
        case .system: return "room"
        }
    }
}

extension ASRVersion {
    /// The FluidAudio checkpoint this setting selects.
    var fluidVersion: AsrModelVersion {
        switch self {
        case .v3: return .v3
        case .v2: return .v2
        }
    }

    /// The repository the checkpoint lives in — `AsrModelVersion.repo` is internal to
    /// FluidAudio, so the mapping is repeated here rather than reached into.
    var repo: Repo {
        switch self {
        case .v3: return .parakeetV3
        case .v2: return .parakeetV2
        }
    }

    /// The name written to `meta.models.asr` and `transcript.json`.
    /// `parakeet-tdt-0.6b-v3`, which is FluidAudio's own folder name for the repo.
    var modelIdentifier: String { repo.folderName }
}
