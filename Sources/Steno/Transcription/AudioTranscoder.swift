import AVFoundation
import Foundation

/// Turns the finished `audio.wav` into the archive format the user picked.
///
/// Recording is always lossless WAV: it streams, it survives a crash, and the two
/// channels of an `online` file stay sample-exact. None of that matters once the
/// transcript is written, and an hour of 48 kHz stereo PCM is 660 MB — so the archive
/// is produced afterwards, from a file the models have already read.
///
/// **The channels are not touched.** An `online` archive stays two channels in the same
/// order: ch0 the tapped system audio, ch1 the microphone. That is what makes the file
/// interpretable at all (`meta.channels`), and a downmix to mono would throw away the
/// one physical fact the transcript's `ME` rests on.
///
/// **A failed transcode is not a failed meeting.** The WAV is only deleted once the
/// archive exists and reads back with the right channel count and length; anything else
/// leaves the WAV in place, writes `meta.audio = "audio.wav"`, and logs why.
enum AudioTranscoder {
    /// What the archive step produced.
    struct Result: Sendable, Equatable {
        /// The file name for `meta.audio`.
        var fileName: String
        var channels: Int
        var duration: TimeInterval
        var bytes: Int64
        /// Set when the wanted format could not be produced and something else was.
        var fallbackReason: String?
    }

    enum Failure: LocalizedError, CustomStringConvertible {
        case sourceMissing(URL)
        case unreadable(String)
        case writerRefused(String)
        case exportFailed(String)
        case verificationFailed(String)

        var description: String {
            switch self {
            case .sourceMissing(let url): return "there is no audio at \(url.lastPathComponent)"
            case .unreadable(let detail): return "the WAV could not be read: \(detail)"
            case .writerRefused(let detail): return "the writer refused the format: \(detail)"
            case .exportFailed(let detail): return "the export failed: \(detail)"
            case .verificationFailed(let detail): return "the archive is not usable: \(detail)"
            }
        }

        var errorDescription: String? {
            String(
                format: String(localized: "Das Audio-Archiv ließ sich nicht schreiben: %@"),
                description
            )
        }
    }

    /// Bit rate per channel count, from the plan: 128 kbps for the two-channel `online`
    /// file, 64 kbps for the one-channel `onsite` one. Both are far above the point
    /// where AAC costs a recognizer anything, which is why transcription runs first
    /// and the archive can be this small.
    static func bitRate(forChannels channels: Int) -> Int {
        channels >= 2 ? 128_000 : 64_000
    }

    /// Writes the archive and, on success, removes the WAV.
    ///
    /// - Returns: what `meta.audio` should say, plus the numbers worth logging.
    static func archive(
        wav: URL,
        as format: AudioArchiveFormat,
        in folder: URL
    ) async throws -> Result {
        guard FileManager.default.fileExists(atPath: wav.stenoPath) else {
            throw Failure.sourceMissing(wav)
        }

        let source = try AVAudioFile(forReading: wav)
        let channels = Int(source.processingFormat.channelCount)
        let duration = Double(source.length) / source.processingFormat.sampleRate

        switch format {
        case .wav:
            // Nothing to do, and nothing to delete.
            return Result(
                fileName: AudioArchiveFormat.wav.audioFileName,
                channels: channels,
                duration: duration,
                bytes: size(of: wav)
            )

        case .aac:
            let destination = folder.appendingPathComponent(AudioArchiveFormat.aac.audioFileName)
            try await writeCompressed(
                from: wav,
                to: destination,
                formatID: kAudioFormatMPEG4AAC,
                bitRate: bitRate(forChannels: channels),
                channels: channels,
                sampleRate: source.processingFormat.sampleRate
            )
            let result = try verify(
                destination: destination,
                expectedChannels: channels,
                expectedDuration: duration,
                fallbackReason: nil
            )
            remove(wav)
            return result

        case .flac:
            let destination = folder.appendingPathComponent(AudioArchiveFormat.flac.audioFileName)
            do {
                try writeLossless(
                    from: wav,
                    to: destination,
                    formatID: kAudioFormatFLAC,
                    channels: channels,
                    sampleRate: source.processingFormat.sampleRate
                )
                let result = try verify(
                    destination: destination,
                    expectedChannels: channels,
                    expectedDuration: duration,
                    fallbackReason: nil
                )
                remove(wav)
                return result
            } catch {
                // AVFoundation writes FLAC on macOS, but the encoder can refuse a
                // channel layout or a sample rate on some machines. ALAC is the same
                // promise — lossless, about half the size — in a container macOS
                // always writes, so the archive setting is honoured rather than
                // silently downgraded to AAC.
                try? FileManager.default.removeItem(at: destination)
                let reason = "FLAC unavailable (\(error.localizedDescription)); wrote ALAC instead"
                Log.transcription.notice("\(reason, privacy: .public)")
                let alac = folder.appendingPathComponent(AudioArchiveFormat.aac.audioFileName)
                try await writeCompressed(
                    from: wav,
                    to: alac,
                    formatID: kAudioFormatAppleLossless,
                    bitRate: nil,
                    channels: channels,
                    sampleRate: source.processingFormat.sampleRate
                )
                let result = try verify(
                    destination: alac,
                    expectedChannels: channels,
                    expectedDuration: duration,
                    fallbackReason: reason
                )
                remove(wav)
                return result
            }
        }
    }

    // MARK: - Writing

    /// AAC or ALAC into an `.m4a`, through `AVAssetWriter`.
    ///
    /// `AVAssetExportSession` would be shorter, but its presets decide the channel
    /// count for you — `AVAssetExportPresetAppleM4A` downmixes to mono what it feels
    /// like downmixing — and the two channels are exactly what must survive. A writer
    /// with an explicit output setting keeps them.
    private static func writeCompressed(
        from source: URL,
        to destination: URL,
        formatID: AudioFormatID,
        bitRate: Int?,
        channels: Int,
        sampleRate: Double
    ) async throws {
        try? FileManager.default.removeItem(at: destination)

        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: channelLayoutData(channels: channels)
        ]
        if let bitRate { settings[AVEncoderBitRateKey] = bitRate }

        try await writeThroughAVFoundation(
            from: source,
            to: destination,
            settings: settings,
            fileType: .m4a
        )
    }

    /// FLAC, through `AVAudioFile`.
    ///
    /// Not through `AVAssetWriter`: `AVFileType` has no FLAC case, and Core Audio's
    /// FLAC encoder is reached through the `ExtAudioFile` layer that `AVAudioFile`
    /// sits on. Written a second at a time, like everything else here.
    private static func writeLossless(
        from source: URL,
        to destination: URL,
        formatID: AudioFormatID,
        channels: Int,
        sampleRate: Double
    ) throws {
        try? FileManager.default.removeItem(at: destination)

        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: formatID,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVChannelLayoutKey: channelLayoutData(channels: channels)
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        let chunk = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw Failure.writerRefused("no buffer for \(format)")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    /// Reads with `AVAssetReader` and writes with `AVAssetWriter`, a sample buffer at a
    /// time. Synchronous by design: this runs on the transcription queue's own task,
    /// after the transcript is already safe on disk.
    private static func writeThroughAVFoundation(
        from source: URL,
        to destination: URL,
        settings: [String: Any],
        fileType: AVFileType
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.unreadable("the file has no audio track")
        }
        let session = try TranscodeSession(
            asset: asset,
            track: track,
            destination: destination,
            settings: settings,
            fileType: fileType
        )

        do {
            // `requestMediaDataWhenReady` pulls from its own queue as the encoder
            // drains, which is what keeps memory flat over an hour of audio; the
            // continuation turns that callback shape back into one `await`.
            try await withCheckedThrowingContinuation { continuation in
                session.pump(resuming: continuation)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        if !session.didComplete {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.exportFailed(session.writerError ?? "the writer did not finish")
        }
    }

    /// One reader, one writer, and the rule that the continuation is resumed once.
    ///
    /// It exists as a class because `requestMediaDataWhenReady` takes a `@Sendable`
    /// closure and AVFoundation's reader and writer are not `Sendable`. They are safe
    /// here for the reason the annotation cannot express: everything that touches them
    /// after `pump` runs on the one serial queue this object owns, and the object is
    /// used for exactly one transcode.
    private final class TranscodeSession: @unchecked Sendable {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let queue = DispatchQueue(label: "de.21m.steno.transcode")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?

        var didComplete: Bool { writer.status == .completed }
        var writerError: String? { writer.error?.localizedDescription }

        init(
            asset: AVURLAsset,
            track: AVAssetTrack,
            destination: URL,
            settings: [String: Any],
            fileType: AVFileType
        ) throws {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(
                track: track,
                // Decoded to PCM in the file's own channel layout; the writer input is
                // what re-encodes, and it is the one that was told to keep the channels.
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            guard reader.canAdd(output) else {
                throw Failure.unreadable("the reader refused the track")
            }
            reader.add(output)

            writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw Failure.writerRefused("\(settings[AVFormatIDKey] ?? "?")")
            }
            writer.add(input)

            guard reader.startReading() else {
                throw Failure.unreadable(
                    reader.error?.localizedDescription ?? "the reader would not start"
                )
            }
            guard writer.startWriting() else {
                throw Failure.writerRefused(
                    writer.error?.localizedDescription ?? "the writer would not start"
                )
            }
            writer.startSession(atSourceTime: .zero)
        }

        /// Copies every sample across and resumes `continuation` when the writer is done.
        func pump(resuming continuation: CheckedContinuation<Void, any Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                        let failure: (any Error)? = reader.status == .failed
                            ? Failure.exportFailed(
                                reader.error?.localizedDescription ?? "the reader failed"
                            )
                            : nil
                        finish(failure)
                        return
                    }
                    if !input.append(sample) {
                        finish(
                            Failure.exportFailed(
                                writer.error?.localizedDescription ?? "the writer rejected a sample"
                            )
                        )
                        return
                    }
                }
            }
        }

        /// Closes the file and resumes the continuation — at most once.
        ///
        /// `requestMediaDataWhenReady` can call back again after the input has been
        /// marked finished, and resuming a continuation twice is a crash rather than a
        /// warning, so the one-shot rule is enforced rather than assumed.
        private func finish(_ error: (any Error)?) {
            input.markAsFinished()
            writer.finishWriting { [self] in
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                guard let pending else { return }
                if let error {
                    pending.resume(throwing: error)
                } else {
                    pending.resume()
                }
            }
        }
    }

    // MARK: - Checking

    /// Reads the archive back before the WAV is deleted.
    ///
    /// This is the whole safety of the step: the original is only thrown away once the
    /// replacement opens, holds the same channels, and is the same length to within a
    /// tenth of a second — encoder padding accounts for the tolerance.
    private static func verify(
        destination: URL,
        expectedChannels: Int,
        expectedDuration: TimeInterval,
        fallbackReason: String?
    ) throws -> Result {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: destination)
        } catch {
            throw Failure.verificationFailed(error.localizedDescription)
        }
        let channels = Int(file.processingFormat.channelCount)
        let duration = Double(file.length) / file.processingFormat.sampleRate

        guard channels == expectedChannels else {
            throw Failure.verificationFailed(
                "\(channels) channel(s) instead of \(expectedChannels)"
            )
        }
        guard abs(duration - expectedDuration) <= max(0.1, expectedDuration * 0.01) else {
            throw Failure.verificationFailed(
                String(format: "%.2f s instead of %.2f s", duration, expectedDuration)
            )
        }

        return Result(
            fileName: destination.lastPathComponent,
            channels: channels,
            duration: duration,
            bytes: size(of: destination),
            fallbackReason: fallbackReason
        )
    }

    // MARK: - Bits and pieces

    /// A plain mono or stereo layout, so the two channels keep their identity in the
    /// container rather than being written as an anonymous pair.
    private static func channelLayoutData(channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels >= 2
            ? kAudioChannelLayoutTag_Stereo
            : kAudioChannelLayoutTag_Mono
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    private static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.transcription.error(
                "could not remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.stenoPath)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
