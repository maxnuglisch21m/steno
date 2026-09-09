import AVFoundation
import Foundation

/// Streams audio buffers into `audio.wav` — 48 kHz, 16-bit PCM, one or two channels.
///
/// Both recorders write through this: `MicRecorder` (M1) with one channel from the
/// room microphone, `ProcessTapRecorder` (M2) with two. The format is fixed by
/// specification §3a and §3b and is not negotiable — no processing happens here, only
/// whatever format conversion the input demands.
///
/// Two properties matter more than anything else about this class:
///
/// - **Nothing is buffered.** Specification §3a.3: an hour of audio has to survive a
///   crash, so every buffer goes to disk as it arrives and the file on disk is always
///   almost complete. What is kept in memory is one converted buffer at a time.
/// - **The caller never waits for the disk.** `write(_:)` copies the buffer and
///   returns; the conversion and the file write happen on this writer's own serial
///   queue. The audio tap callback that calls it is not a place to block on I/O.
///
/// A serial `DispatchQueue` rather than an actor, deliberately: dispatch guarantees
/// the buffers are processed in the order they were submitted, which is the difference
/// between a recording and a shuffled one. `Task { await … }` per buffer gives no such
/// ordering guarantee, and would allocate a task 12 times a second.
final class WAVWriter {
    /// What the finished file holds.
    struct Result: Sendable, Equatable {
        var frameCount: Int64
        var duration: TimeInterval
        /// The file name, for `meta.audio`.
        var fileName: String
    }

    enum WriterError: LocalizedError, CustomStringConvertible {
        case unsupportedChannelCount(Int)
        case formatUnavailable
        case noConverter(from: String, to: String)
        case conversionFailed(String)

        var description: String {
            switch self {
            case .unsupportedChannelCount(let n):
                return "a WAV writer takes 1 or 2 channels, not \(n)"
            case .formatUnavailable:
                return "48 kHz 16-bit PCM is not a format AVFoundation would build"
            case .noConverter(let from, let to):
                return "no converter from \(from) to \(to)"
            case .conversionFailed(let detail):
                return "sample-rate conversion failed: \(detail)"
            }
        }

        var errorDescription: String? { description }
    }

    /// The recording sample rate. Fixed by the specification, in both modes.
    static let sampleRate: Double = 48_000
    /// The name every recorder writes. `meta.audio` may later name a transcode of it.
    static let fileName = "audio.wav"

    let url: URL
    /// 48 kHz, 16-bit signed integer, interleaved, `channelCount` channels. Buffers in
    /// this format are written straight through; anything else is converted.
    let format: AVAudioFormat

    /// Everything below is touched only on `queue`, except `counter` and `failure`,
    /// which have their own lock because they are read from the outside.
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?

    private let stateLock = NSLock()
    private var frameCounter: Int64 = 0
    private var failure: Error?
    private var hasLoggedFailure = false

    /// Called once, off the main actor, when a write or a conversion fails — a full
    /// disk being the case that matters. The recording is over at that point; the
    /// coordinator turns it into `state: failed`.
    private let onError: (@Sendable (Error) -> Void)?

    /// Opens the file and writes its header. Throws if the folder is not writable.
    init(
        folder: URL,
        channelCount: Int,
        fileName: String = WAVWriter.fileName,
        onError: (@Sendable (Error) -> Void)? = nil
    ) throws {
        guard (1...2).contains(channelCount) else {
            throw WriterError.unsupportedChannelCount(channelCount)
        }
        self.url = folder.appendingPathComponent(fileName)
        self.onError = onError
        self.queue = DispatchQueue(
            label: "de.21m.steno.wav-writer",
            qos: .userInitiated
        )

        // The file format. 16-bit little-endian integer PCM, interleaved: canonical
        // WAV, and the one layout `StenoCore.WAVHeader` can repair after a crash.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // `commonFormat: .pcmFormatInt16, interleaved: true` makes the processing
        // format identical to the file format, so a buffer that already arrives as
        // 48 kHz Int16 is written with no conversion at all.
        let opened = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        self.file = opened
        self.format = opened.processingFormat

        Log.audio.notice(
            """
            WAV writer opened: \(channelCount, privacy: .public) ch, \
            \(Int(Self.sampleRate), privacy: .public) Hz, 16 bit
            """
        )
    }

    // MARK: - Reading state from the outside

    /// Frames written so far. Safe to read from any thread.
    var framesWritten: Int64 {
        stateLock.withLock { frameCounter }
    }

    /// The error that ended the writing, if one did.
    var writeFailure: Error? {
        stateLock.withLock { failure }
    }

    // MARK: - Writing

    /// Hands one buffer over for writing. Returns immediately.
    ///
    /// Accepts Float32 or Int16 input at any sample rate and channel count: an
    /// `AVAudioConverter` bridges whatever the device delivers to the file's format.
    /// Safe to call from an audio tap callback, which is the only caller that exists.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        // The tap's buffer is only valid for the duration of the callback, so it is
        // copied here — a memcpy of at most a few tens of kilobytes, no I/O — and the
        // copy is what travels to the writer queue.
        guard let copy = buffer.copied() else {
            Log.audio.error("could not copy an audio buffer; \(buffer.frameLength, privacy: .public) frames dropped")
            return
        }
        let handover = BufferHandover(copy)
        queue.async { [weak self] in
            self?.consume(handover.buffer)
        }
    }

    /// Flushes, closes the file, and reports what it holds.
    ///
    /// Synchronous on purpose: it returns only once every buffer submitted before it
    /// has reached the disk, which is what makes the frame count in `meta.json` the
    /// truth rather than a guess.
    @discardableResult
    func close() -> Result {
        queue.sync {
            flushConverter()
            // `AVAudioFile` finalizes the RIFF and `data` sizes when it is released,
            // so the file is closed by letting go of it — not by any explicit call.
            file = nil
            converter = nil
            converterInputFormat = nil
            scratch = nil
        }
        let frames = framesWritten
        let result = Result(
            frameCount: frames,
            duration: TimeInterval(frames) / Self.sampleRate,
            fileName: url.lastPathComponent
        )
        Log.audio.notice(
            """
            WAV writer closed: \(frames, privacy: .public) frames, \
            \(String(format: "%.1f", result.duration), privacy: .public) s
            """
        )
        return result
    }

    // MARK: - On the writer queue

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let file, writeFailure == nil else { return }
        do {
            if buffer.format.isEquivalent(to: format) {
                try file.write(from: buffer)
                add(frames: Int64(buffer.frameLength))
                return
            }
            try convertAndWrite(buffer, to: file)
        } catch {
            report(error)
        }
    }

    /// Converts one input buffer into the file's format and writes everything the
    /// converter gives back.
    ///
    /// The converter is kept across calls, which is what makes sample-rate conversion
    /// continuous: a resampler holds state at the boundary between two buffers, and a
    /// fresh converter per buffer would put a click there every 85 ms.
    private func convertAndWrite(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) throws {
        if converterInputFormat?.isEquivalent(to: buffer.format) != true {
            // A configuration change can hand the tap a new sample rate mid-recording
            // (specification §3b says nothing about it, but a Mac waking a device up
            // does it). Rebuilding here keeps the file at 48 kHz regardless.
            guard let fresh = AVAudioConverter(from: buffer.format, to: format) else {
                throw WriterError.noConverter(
                    from: buffer.format.description,
                    to: format.description
                )
            }
            Log.audio.notice(
                "WAV writer converting from \(buffer.format.description, privacy: .public)"
            )
            converter = fresh
            converterInputFormat = buffer.format
            scratch = nil
        }
        guard let converter else { throw WriterError.formatUnavailable }

        // Room for the resampled frames plus the converter's own priming latency.
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
        let output = try scratchBuffer(atLeast: capacity)

        // One buffer per call: the source hands it over once and then reports
        // `noDataNow`, which tells the converter to give back what it has and keep the
        // rest of its resampler state for the next buffer.
        let source = SingleBufferSource(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            source.next(outStatus)
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw WriterError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown"
            )
        @unknown default:
            throw WriterError.conversionFailed("unexpected converter status \(status.rawValue)")
        }

        guard output.frameLength > 0 else { return }
        try file.write(from: output)
        add(frames: Int64(output.frameLength))
    }

    /// The last frames the resampler is still holding, on the way out.
    private func flushConverter() {
        guard let converter, let file, writeFailure == nil else { return }
        do {
            let output = try scratchBuffer(atLeast: 4096)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if status == .error {
                Log.audio.error(
                    "flushing the converter failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)"
                )
                return
            }
            guard output.frameLength > 0 else { return }
            try file.write(from: output)
            add(frames: Int64(output.frameLength))
        } catch {
            Log.audio.error("could not flush the converter: \(String(describing: error), privacy: .public)")
        }
    }

    /// One reused output buffer, grown when a larger input arrives. Allocating one per
    /// buffer would put 12 allocations a second on the writer queue for no reason.
    private func scratchBuffer(atLeast capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if let scratch, scratch.frameCapacity >= capacity {
            scratch.frameLength = 0
            return scratch
        }
        guard let fresh = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WriterError.formatUnavailable
        }
        scratch = fresh
        return fresh
    }

    private func add(frames: Int64) {
        stateLock.withLock { frameCounter += frames }
    }

    /// Records the first failure, logs it once, and tells the coordinator.
    private func report(_ error: Error) {
        let shouldNotify: Bool = stateLock.withLock {
            guard failure == nil else { return false }
            failure = error
            guard !hasLoggedFailure else { return false }
            hasLoggedFailure = true
            return true
        }
        guard shouldNotify else { return }
        Log.audio.error("WAV write failed: \(String(describing: error), privacy: .public)")
        // Stop touching the file at all: a disk that is full stays full, and retrying
        // once a buffer would fill the log instead of the file.
        file = nil
        onError?(error)
    }
}

// `WAVWriter` has mutable state and is handed to an audio tap callback, so the
// compiler has to be told why that is safe: `file`, `converter`, and `scratch` are
// only ever touched inside `queue`, and `frameCounter` and `failure` — the two values
// read from other threads — are behind `stateLock`. There is no path that reaches the
// former from outside the queue.
extension WAVWriter: @unchecked Sendable {}

// MARK: - Getting a buffer across a thread boundary

/// Carries one privately owned `AVAudioPCMBuffer` from the audio thread to the writer
/// queue.
///
/// `AVAudioPCMBuffer` is not `Sendable`, and rightly so — it is a mutable box around
/// raw samples. This one is safe to move because it is a fresh copy made in
/// `WAVWriter.write` for this hand-over alone: the audio thread never looks at it
/// again after submitting it, and the writer queue is the only thing that touches it
/// afterwards. Exactly one owner at any moment, which is what `Sendable` is asking
/// about.
private struct BufferHandover: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Hands one buffer to `AVAudioConverter`, once.
///
/// `AVAudioConverterInputBlock` is declared `@Sendable`, but the converter calls it
/// synchronously from `convert(to:error:withInputFrom:)`, on the same thread, before
/// that call returns — so neither the buffer nor the flag below ever crosses a thread
/// boundary. This class says so where the compiler cannot see it, instead of the
/// alternative, which is capturing a mutable `var` in a `@Sendable` closure and hoping.
private final class SingleBufferSource: @unchecked Sendable {
    private var pending: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.pending = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        guard let buffer = pending else {
            status.pointee = .noDataNow
            return nil
        }
        pending = nil
        status.pointee = .haveData
        return buffer
    }
}

// MARK: - Buffer copying

extension AVAudioPCMBuffer {
    /// A deep copy of the frames this buffer currently holds.
    ///
    /// Needed because an `installTap` buffer is only valid for the length of the
    /// callback: it is reused for the next slice of audio the moment the block
    /// returns. Copies the raw `AudioBufferList` bytes, so it works for every common
    /// format — Float32 or Int16, interleaved or not — rather than only the one the
    /// built-in microphone happens to use today.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            guard
                let from = source[index].mData,
                let into = destination[index].mData
            else { return nil }
            let bytes = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            memcpy(into, from, bytes)
        }
        return copy
    }
}

extension AVAudioFormat {
    /// Whether two formats are close enough that no conversion is needed.
    ///
    /// `isEqual(_:)` on `AVAudioFormat` compares the channel layout too, and a tap
    /// format carries one where a file's processing format may not — which would make
    /// two identical 48 kHz Int16 streams look different and route them through a
    /// pointless converter.
    func isEquivalent(to other: AVAudioFormat) -> Bool {
        commonFormat == other.commonFormat
            && sampleRate == other.sampleRate
            && channelCount == other.channelCount
            && isInterleaved == other.isInterleaved
    }
}
