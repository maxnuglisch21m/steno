import AVFoundation
import Foundation
import StenoCore
import Testing

@testable import Steno

/// The writer that both modes record through. What is checked here is the one thing a
/// downstream tool depends on: the file on disk is a 48 kHz 16-bit PCM WAV whose header
/// describes its own contents, whatever format the hardware handed in.
@Suite("WAVWriter")
struct WAVWriterTests {
    /// A throwaway folder, removed when the test ends.
    private struct Folder: ~Copyable {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("steno-wav-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        var audio: URL { url.appendingPathComponent(WAVWriter.fileName) }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// One second of 440 Hz at the given rate, as the tap would deliver it.
    private static func sine(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let step = 2 * Float.pi * 440 / Float(format.sampleRate)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                let value = sin(step * Float(frame)) * amplitude
                if let floats = buffer.floatChannelData {
                    floats[channel][frame] = value
                } else if let ints = buffer.int16ChannelData {
                    let index = buffer.format.isInterleaved
                        ? frame * Int(format.channelCount) + channel
                        : frame
                    let target = buffer.format.isInterleaved ? ints[0] : ints[channel]
                    target[index] = Int16(value * 32_767)
                }
            }
        }
        return buffer
    }

    private static func header(of url: URL) throws -> (WAVHeader, Int) {
        let data = try Data(contentsOf: url)
        return (try WAVHeader.parse(data), data.count)
    }

    // MARK: - The format the specification fixes

    @Test("writes a 48 kHz 16-bit mono WAV whose header matches the file")
    func writesMonoInt16() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 1)

        // Int16 at 48 kHz: exactly the writer's own format, so nothing is converted.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: WAVWriter.sampleRate,
            channels: 1,
            interleaved: true
        )!
        let frames: AVAudioFrameCount = 48_000
        writer.write(Self.sine(format: format, frames: frames))
        let result = writer.close()

        #expect(result.frameCount == Int64(frames))
        #expect(abs(result.duration - 1.0) < 0.001)
        #expect(result.fileName == "audio.wav")

        let (header, fileSize) = try Self.header(of: folder.audio)
        #expect(header.format.channelCount == 1)
        #expect(header.format.sampleRate == 48_000)
        #expect(header.format.bitsPerSample == 16)
        #expect(header.format.audioFormat == WAVHeader.Format.pcmFormat)
        // Mono 16-bit: two bytes a frame, and the header has to say so — this is the
        // number M6's crash repair recomputes from the file length.
        #expect(header.declaredDataSize == UInt32(frames) * 2)
        #expect(header.validate(fileSize: fileSize).isValid)
        #expect(header.validate(fileSize: fileSize).frameCount == Int(frames))

        // And AVFoundation agrees, which is what transcription will read it with.
        let reopened = try AVAudioFile(forReading: folder.audio)
        #expect(reopened.length == Int64(frames))
        #expect(reopened.fileFormat.sampleRate == 48_000)
        #expect(reopened.fileFormat.channelCount == 1)
    }

    @Test("a stereo 44.1 kHz Float32 input arrives as 48 kHz mono Int16")
    func convertsRateFormatAndChannels() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 1)

        // What a USB interface running at CD rate delivers: two channels, floats.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let seconds = 2
        for _ in 0..<(seconds * 10) {
            writer.write(Self.sine(format: format, frames: 4_410))
        }
        let result = writer.close()

        // Resampling has priming latency at the start, so the count is close rather
        // than exact — but a two-second recording must not come out as 1.8 seconds.
        #expect(abs(result.duration - Double(seconds)) < 0.05)

        let (header, fileSize) = try Self.header(of: folder.audio)
        #expect(header.format.channelCount == 1)
        #expect(header.format.sampleRate == 48_000)
        #expect(header.format.bitsPerSample == 16)
        #expect(header.validate(fileSize: fileSize).isValid)
        #expect(header.declaredDataSize == UInt32(result.frameCount) * 2)

        let reopened = try AVAudioFile(forReading: folder.audio)
        #expect(reopened.length == result.frameCount)
    }

    @Test("two channels are written interleaved, for M2")
    func writesStereo() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 2)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        writer.write(Self.sine(format: format, frames: 4_800))
        let result = writer.close()

        let (header, fileSize) = try Self.header(of: folder.audio)
        #expect(header.format.channelCount == 2)
        #expect(header.format.blockAlign == 4)
        #expect(header.declaredDataSize == UInt32(result.frameCount) * 4)
        #expect(header.validate(fileSize: fileSize).isValid)
    }

    @Test("refuses a channel count no mode uses", arguments: [0, 3, 8])
    func refusesOtherChannelCounts(count: Int) throws {
        let folder = try Folder()
        #expect(throws: WAVWriter.WriterError.self) {
            _ = try WAVWriter(folder: folder.url, channelCount: count)
        }
    }

    // MARK: - Behaviour under load and at the edges

    @Test("the samples survive the trip, rather than a file of silence")
    func keepsTheSignal() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        writer.write(Self.sine(format: format, frames: 4_800, amplitude: 0.5))
        _ = writer.close()

        let file = try AVAudioFile(forReading: folder.audio)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(buffer.floatChannelData![0][index]))
        }
        // A half-scale sine has to come back at half scale: no gain is applied on the
        // way in, and none is expected on the way out either (specification §3b.3).
        #expect(peak > 0.45 && peak < 0.55)
    }

    @Test("frames written can be read while writing")
    func reportsProgress() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        #expect(writer.framesWritten == 0)
        for _ in 0..<5 {
            writer.write(Self.sine(format: format, frames: 4_800))
        }
        let result = writer.close()
        #expect(result.frameCount == 24_000)
        #expect(writer.framesWritten == 24_000)
        #expect(writer.writeFailure == nil)
    }

    @Test("an empty buffer is not written and is not an error")
    func ignoresEmptyBuffers() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        empty.frameLength = 0
        writer.write(empty)
        let result = writer.close()
        #expect(result.frameCount == 0)
        #expect(writer.writeFailure == nil)
        // The header is still a valid one, so a recording that captured nothing is an
        // empty WAV rather than a file no reader will open.
        let (header, fileSize) = try Self.header(of: folder.audio)
        #expect(header.validate(fileSize: fileSize).isValid)
        #expect(header.declaredDataSize == 0)
    }

    @Test("closing twice is safe")
    func closesIdempotently() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        writer.write(Self.sine(format: format, frames: 4_800))
        let first = writer.close()
        let second = writer.close()
        #expect(first.frameCount == second.frameCount)
    }

    @Test("opening in a folder that does not exist throws instead of losing audio")
    func refusesAnUnwritableFolder() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: (any Error).self) {
            _ = try WAVWriter(folder: missing, channelCount: 1)
        }
    }

    // MARK: - The header while the file is still open (M6)

    @Test("the header of an open file reports the audio already written")
    func refreshesTheHeaderWhileRecording() throws {
        // The claim being tested is the one the refresh rests on: a second descriptor
        // may write the two size fields of a file `AVAudioFile` is appending through,
        // and `AVAudioFile` neither loses the samples nor fights over the header.
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 1)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: WAVWriter.sampleRate,
            channels: 1,
            interleaved: true
        )!
        let frames: AVAudioFrameCount = 24_000
        writer.write(Self.sine(format: format, frames: frames))
        writer.write(Self.sine(format: format, frames: frames))

        // Before the refresh: what a crash right now would leave behind, and what the
        // recovery pass exists for.
        let (stale, staleSize) = try Self.header(of: folder.audio)
        #expect(stale.declaredDataSize == 0)
        #expect(stale.validate(fileSize: staleSize).needsRepair)
        #expect(stale.validate(fileSize: staleSize).frameCount == Int(frames) * 2)

        writer.refreshHeaderNow()

        // After: the file describes itself, without having been closed.
        let (fresh, freshSize) = try Self.header(of: folder.audio)
        #expect(fresh.declaredDataSize == UInt32(frames) * 2 * 2)
        #expect(fresh.validate(fileSize: freshSize).isValid)
        #expect(abs(fresh.validate(fileSize: freshSize).duration - 1.0) < 0.001)

        // And AVFoundation, which is what a player and the transcription both use,
        // opens it mid-recording and sees the right length.
        let midRecording = try AVAudioFile(forReading: folder.audio)
        #expect(midRecording.length == Int64(frames) * 2)

        // Writing continues afterwards, and the close still produces a valid file: the
        // refresh must not have confused `AVAudioFile` about where it was.
        writer.write(Self.sine(format: format, frames: frames))
        let result = writer.close()
        #expect(result.frameCount == Int64(frames) * 3)

        let (closed, closedSize) = try Self.header(of: folder.audio)
        #expect(closed.validate(fileSize: closedSize).isValid)
        #expect(closed.declaredDataSize == UInt32(frames) * 3 * 2)
        let reopened = try AVAudioFile(forReading: folder.audio)
        #expect(reopened.length == Int64(frames) * 3)
    }

    @Test("refreshing a file with nothing in it yet changes nothing")
    func refreshOnAnEmptyFile() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 2)
        writer.refreshHeaderNow()

        let (header, size) = try Self.header(of: folder.audio)
        #expect(header.declaredDataSize == 0)
        #expect(header.validate(fileSize: size).frameCount == 0)
        writer.close()
    }

    @Test("refreshing a closed writer is harmless")
    func refreshAfterClose() throws {
        let folder = try Folder()
        let writer = try WAVWriter(folder: folder.url, channelCount: 1)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: WAVWriter.sampleRate,
            channels: 1,
            interleaved: true
        )!
        writer.write(Self.sine(format: format, frames: 4_800))
        let result = writer.close()
        writer.refreshHeaderNow()

        let (header, size) = try Self.header(of: folder.audio)
        #expect(header.validate(fileSize: size).isValid)
        #expect(header.declaredDataSize == UInt32(result.frameCount) * 2)
    }

}
