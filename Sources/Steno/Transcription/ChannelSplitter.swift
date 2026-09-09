import AVFoundation
import Foundation
import StenoCore

/// Turns `audio.wav` into the one-channel 16 kHz files the models read.
///
/// Specification §5 asks for "je 16 kHz Mono Float32 — immer über AudioConverter,
/// niemals WAV-Bytes selbst parsen", and the reason for the second half is that a WAV
/// written by a crashed recording has a header that lies about its length.
/// `AVAudioFile` is the reader, and `AVAudioConverter` is the resampler; no byte of the
/// container is interpreted here.
///
/// FluidAudio's own `AudioConverter` cannot do this: it downmixes every channel to
/// mono, and there is no channel parameter anywhere in its API. An `online` recording's
/// two channels are the whole point — ch0 is the meeting, ch1 is the user — so the
/// split happens here and FluidAudio is handed two finished files.
///
/// **Nothing is held in memory.** The source is read a second at a time and each chunk
/// is converted and written before the next is read, so an hour of audio costs a few
/// hundred kilobytes of buffers rather than 700 MB.
enum ChannelSplitter {
    /// The scratch directory inside the meeting folder. Deleted when transcription
    /// succeeds, left behind when it fails — a failed run's inputs are the only way to
    /// find out why it failed.
    static let workDirectoryName = "_work"
    /// Channel 0: the room microphone (`onsite`) or the tapped system audio (`online`).
    static let roomFileName = "room16k.wav"
    /// Channel 1: the microphone of an `online` recording.
    static let micFileName = "mic16k.wav"

    /// What the models read, and what has to be cleaned up afterwards.
    struct Output: Sendable {
        var room: URL
        /// `nil` for `onsite`, and for an `online` file that turned out to have one
        /// channel — a recording whose microphone never arrived.
        var mic: URL?
        var workDirectory: URL
        /// Length of the source, from its frame count rather than from `meta.json`.
        var duration: TimeInterval
        var sourceChannels: Int
        var sourceSampleRate: Double
    }

    enum Failure: LocalizedError, CustomStringConvertible {
        case audioMissing(URL)
        case noChannels
        case emptyAudio
        case converterUnavailable(from: String, to: String)
        case conversionFailed(String)

        var description: String {
            switch self {
            case .audioMissing(let url):
                return "there is no audio at \(url.lastPathComponent)"
            case .noChannels:
                return "the audio file reports no channels"
            case .emptyAudio:
                return "the audio file holds no samples"
            case .converterUnavailable(let from, let to):
                return "no converter from \(from) to \(to)"
            case .conversionFailed(let detail):
                return "resampling failed: \(detail)"
            }
        }

        var errorDescription: String? {
            switch self {
            case .audioMissing:
                return String(localized: "Die Audiodatei des Meetings fehlt.")
            case .noChannels, .emptyAudio:
                return String(localized: "Die Audiodatei enthält keine Aufnahme.")
            case .converterUnavailable, .conversionFailed:
                return String(localized: "Die Audiodatei ließ sich nicht auf 16 kHz umrechnen.")
            }
        }
    }

    /// What the models want: 16 kHz, mono, Float32.
    static let targetSampleRate: Double = 16_000

    /// How much of the source is read at a time. One second at the recording rate —
    /// small enough that memory is flat, large enough that the resampler is not being
    /// restarted every few milliseconds.
    static let chunkSeconds: Double = 1

    /// `<folder>/_work`.
    static func workDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent(workDirectoryName, isDirectory: true)
    }

    /// Removes the scratch directory. Called on success, and on a retry before the
    /// files are written again.
    static func removeWorkDirectory(in folder: URL) {
        try? FileManager.default.removeItem(at: workDirectory(in: folder))
    }

    /// Splits the meeting's audio into one 16 kHz mono file per channel.
    ///
    /// - Parameters:
    ///   - audio: `<folder>/audio.wav`.
    ///   - folder: the meeting folder; `_work` is created inside it.
    ///   - wantsMic: whether channel 1 is wanted. `true` for `online`, and ignored when
    ///     the file has only one channel.
    static func split(audio: URL, in folder: URL, wantsMic: Bool) throws -> Output {
        guard FileManager.default.fileExists(atPath: audio.stenoPath) else {
            throw Failure.audioMissing(audio)
        }

        let source = try AVAudioFile(forReading: audio)
        let format = source.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount >= 1 else { throw Failure.noChannels }
        guard source.length > 0 else { throw Failure.emptyAudio }

        let work = workDirectory(in: folder)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // Channel 1 only when the file actually has one. An `online` recording whose
        // microphone never opened is a one-channel file, and asking for a channel that
        // is not there would fail the whole transcription over the half that is fine.
        let wantsMic = wantsMic && channelCount >= 2
        var channels: [Int] = [0]
        if wantsMic { channels.append(1) }

        let writers = try channels.map { index in
            try ChannelWriter(
                url: work.appendingPathComponent(index == 0 ? roomFileName : micFileName),
                sourceFormat: format
            )
        }

        // One mono scratch buffer per channel, reused for every chunk.
        let chunkFrames = AVAudioFrameCount(max(1, format.sampleRate * chunkSeconds))
        guard
            let interleaved = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames)
        else {
            throw Failure.converterUnavailable(from: "\(format)", to: "16 kHz mono")
        }

        while source.framePosition < source.length {
            try source.read(into: interleaved, frameCount: chunkFrames)
            let frames = Int(interleaved.frameLength)
            if frames == 0 { break }
            for (slot, channel) in channels.enumerated() {
                extract(channel: channel, from: interleaved, into: mono, frames: frames)
                try writers[slot].write(mono)
            }
        }
        for writer in writers { try writer.finish() }

        let duration = Double(source.length) / format.sampleRate
        Log.transcription.notice(
            """
            split \(channelCount, privacy: .public) ch × \
            \(Int(format.sampleRate), privacy: .public) Hz \
            (\(String(format: "%.1f", duration), privacy: .public) s) into \
            \(channels.count, privacy: .public) work file(s)
            """
        )

        return Output(
            room: writers[0].url,
            mic: wantsMic ? writers[1].url : nil,
            workDirectory: work,
            duration: duration,
            sourceChannels: channelCount,
            sourceSampleRate: format.sampleRate
        )
    }

    /// Copies one channel of an interleaved or deinterleaved buffer into a mono buffer.
    ///
    /// `AVAudioFile.processingFormat` is deinterleaved Float32 for a PCM WAV, so the
    /// usual path is the second branch; the first is there because a format that
    /// arrives interleaved must not silently produce a channel of noise.
    private static func extract(
        channel: Int,
        from buffer: AVAudioPCMBuffer,
        into mono: AVAudioPCMBuffer,
        frames: Int
    ) {
        mono.frameLength = AVAudioFrameCount(frames)
        guard let destination = mono.floatChannelData?[0] else { return }
        let channelCount = Int(buffer.format.channelCount)
        guard let source = buffer.floatChannelData else {
            destination.update(repeating: 0, count: frames)
            return
        }
        if buffer.format.isInterleaved {
            let base = source[0]
            for frame in 0..<frames {
                destination[frame] = base[frame * channelCount + channel]
            }
        } else {
            destination.update(from: source[channel], count: frames)
        }
    }

    /// The one buffer an `AVAudioConverter` call is allowed to consume, and what to say
    /// once it has.
    ///
    /// `endOfStream` flushes the resampler's filter delay and is used only on the final
    /// drain; `noDataNow` leaves that state intact so the next chunk continues the same
    /// stream — which is the difference between a clean resampling and a click at every
    /// second boundary.
    private final class PendingInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        private let isDraining: Bool

        init(buffer: AVAudioPCMBuffer?, isDraining: Bool) {
            self.buffer = buffer
            self.isDraining = isDraining
        }

        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
            if let buffer {
                self.buffer = nil
                status.pointee = .haveData
                return buffer
            }
            status.pointee = isDraining ? .endOfStream : .noDataNow
            return nil
        }
    }

    /// One output channel: a resampler and the file it writes into.
    ///
    /// The converter is kept for the whole recording rather than rebuilt per chunk,
    /// because a sample-rate converter carries filter state across its input — a fresh
    /// one per chunk would put a click at every second boundary.
    private final class ChannelWriter {
        let url: URL
        private let converter: AVAudioConverter
        private let file: AVAudioFile
        private let outputFormat: AVAudioFormat
        private let ratio: Double

        init(url: URL, sourceFormat: AVAudioFormat) throws {
            self.url = url
            guard
                let monoSource = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sourceFormat.sampleRate,
                    channels: 1,
                    interleaved: false
                ),
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: ChannelSplitter.targetSampleRate,
                    channels: 1,
                    interleaved: false
                )
            else {
                throw Failure.converterUnavailable(from: "\(sourceFormat)", to: "16 kHz mono")
            }
            guard let converter = AVAudioConverter(from: monoSource, to: target) else {
                throw Failure.converterUnavailable(from: "\(monoSource)", to: "\(target)")
            }
            self.converter = converter
            self.outputFormat = target
            self.ratio = target.sampleRate / sourceFormat.sampleRate
            // 32-bit float WAV: what the models want, and what `AVAudioFile` reads
            // back without a second conversion. Written to disk rather than kept as
            // `[Float]` so FluidAudio can memory-map it.
            self.file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: target.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }

        /// Resamples one chunk and writes whatever came out.
        func write(_ mono: AVAudioPCMBuffer) throws {
            try convert(feeding: mono)
        }

        /// Drains the resampler's tail and closes the file.
        func finish() throws {
            try convert(feeding: nil)
        }

        private func convert(feeding input: AVAudioPCMBuffer?) throws {
            // Room for the chunk plus the filter's own delay. Generous on purpose: an
            // output buffer that is too small makes `.haveData` come back repeatedly,
            // which is handled, but a too-small one for the *last* call would drop the
            // tail.
            let capacity = AVAudioFrameCount(
                Double(input?.frameLength ?? AVAudioFrameCount(outputFormat.sampleRate)) * ratio + 4096
            )
            // The converter's input block is `@Sendable`, so what it hands out lives in
            // a box rather than in a captured `var`. The box is only ever touched from
            // inside `convert`, which is synchronous — the annotation states that,
            // rather than pretending a buffer is safe to send anywhere.
            let pending = PendingInput(buffer: input, isDraining: input == nil)
            var finished = false

            while !finished {
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
                else { throw Failure.conversionFailed("no output buffer") }

                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, outStatus in
                    pending.next(status: outStatus)
                }

                switch status {
                case .haveData:
                    if output.frameLength > 0 { try file.write(from: output) }
                    // More may be waiting in the converter; ask again.
                case .inputRanDry, .endOfStream:
                    if output.frameLength > 0 { try file.write(from: output) }
                    finished = true
                case .error:
                    throw Failure.conversionFailed(
                        error?.localizedDescription ?? "unknown converter error"
                    )
                @unknown default:
                    finished = true
                }
            }
        }
    }
}
