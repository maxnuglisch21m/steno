import AVFoundation
import Foundation
import StenoCore
import Testing

@testable import Steno

/// The archive step: what `meta.audio` ends up naming, and whether the file it names
/// still holds the recording.
///
/// The check that matters is the channel count. An `online` recording is two channels
/// with a meaning each — ch0 the meeting, ch1 the user — and an encoder that helpfully
/// downmixed them to mono would destroy the physical fact the transcript's `ME` rests
/// on while leaving a file that plays perfectly well.
@Suite("AudioTranscoder", .serialized)
struct AudioTranscoderTests {
    /// A throwaway folder, removed when the test ends.
    ///
    /// A class rather than a non-copyable struct: `#expect` captures its operands, and
    /// a `~Copyable` value cannot be captured — which turns every readable assertion
    /// about the folder into a compiler error.
    private final class Folder {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("steno-archive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        var audio: URL { url.appendingPathComponent(WAVWriter.fileName) }

        func file(_ name: String) -> URL { url.appendingPathComponent(name) }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: file(name).path)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A 48 kHz 16-bit WAV with a different tone in each channel, so a downmix is
    /// visible in the channel count and audible in the samples.
    private static func writeWAV(
        to url: URL,
        frequencies: [Double],
        seconds: Double = 2
    ) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: frequencies.count,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for (channel, frequency) in frequencies.enumerated() {
            let step = 2 * Double.pi * frequency / 48_000
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = Float(sin(step * Double(frame)) * 0.6)
            }
        }
        try file.write(from: buffer)
    }

    // MARK: - AAC, the default

    @Test("an online recording keeps both channels through AAC")
    func aacKeepsTwoChannels() async throws {
        let folder = try Folder()
        try Self.writeWAV(to: folder.audio, frequencies: [440, 880])
        let before = AudioTranscoder.size(of: folder.audio)

        let result = try await AudioTranscoder.archive(wav: folder.audio, as: .aac, in: folder.url)

        #expect(result.fileName == "audio.m4a")
        #expect(result.channels == 2)
        #expect(abs(result.duration - 2) < 0.1)
        #expect(result.fallbackReason == nil)
        // The WAV is gone and the archive is there — in that order, and only because
        // the archive read back correctly.
        #expect(!folder.exists("audio.wav"))
        #expect(folder.exists("audio.m4a"))
        // The point of the exercise: an order of magnitude smaller.
        #expect(result.bytes < before / 4)
    }

    @Test("an onsite recording stays one channel")
    func aacKeepsOneChannel() async throws {
        let folder = try Folder()
        try Self.writeWAV(to: folder.audio, frequencies: [440])

        let result = try await AudioTranscoder.archive(wav: folder.audio, as: .aac, in: folder.url)

        #expect(result.channels == 1)
        let file = try AVAudioFile(forReading: folder.file("audio.m4a"))
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.processingFormat.sampleRate == 48_000)
    }

    @Test("the bit rate follows the channel count")
    func bitRates() {
        #expect(AudioTranscoder.bitRate(forChannels: 2) == 128_000)
        #expect(AudioTranscoder.bitRate(forChannels: 1) == 64_000)
    }

    // MARK: - Keeping the WAV

    @Test("the wav setting leaves everything alone")
    func wavIsKept() async throws {
        let folder = try Folder()
        try Self.writeWAV(to: folder.audio, frequencies: [440, 880])
        let before = AudioTranscoder.size(of: folder.audio)

        let result = try await AudioTranscoder.archive(wav: folder.audio, as: .wav, in: folder.url)

        #expect(result.fileName == "audio.wav")
        #expect(result.channels == 2)
        #expect(result.bytes == before)
        #expect(folder.exists("audio.wav"))
        #expect(!folder.exists("audio.m4a"))
    }

    // MARK: - Lossless

    @Test("the lossless setting produces a lossless file with the same channels")
    func lossless() async throws {
        let folder = try Folder()
        try Self.writeWAV(to: folder.audio, frequencies: [440, 880])

        let result = try await AudioTranscoder.archive(wav: folder.audio, as: .flac, in: folder.url)

        // `audio.flac` on macOS 26, which does write FLAC through `AVAudioFile`. The
        // assertion allows the documented ALAC fallback as well, because the encoder
        // can refuse a channel layout on a machine this test has not run on — both are
        // lossless and both keep the channels, which is what the setting promises, and
        // which of the two happened is recorded in `fallbackReason` rather than hidden.
        #expect(["audio.flac", "audio.m4a"].contains(result.fileName))
        #expect(result.channels == 2)
        #expect(abs(result.duration - 2) < 0.1)
        #expect(!folder.exists("audio.wav"))
        #expect(folder.exists(result.fileName))
        if result.fallbackReason != nil {
            #expect(result.fileName == "audio.m4a")
        }
    }

    // MARK: - Refusals

    @Test("a missing WAV is a refusal, not an empty archive")
    func missingSource() async throws {
        let folder = try Folder()
        await #expect(throws: AudioTranscoder.Failure.self) {
            try await AudioTranscoder.archive(wav: folder.audio, as: .aac, in: folder.url)
        }
        #expect(!folder.exists("audio.m4a"))
    }

    @Test("a file that is not audio leaves the folder as it was")
    func notAudio() async throws {
        let folder = try Folder()
        try Data("this is not a wav".utf8).write(to: folder.audio)

        await #expect(throws: (any Error).self) {
            try await AudioTranscoder.archive(wav: folder.audio, as: .aac, in: folder.url)
        }
        // The rule the whole step rests on: the original survives every failure.
        #expect(folder.exists("audio.wav"))
        #expect(!folder.exists("audio.m4a"))
    }

    // MARK: - What meta.json says

    @Test("every format names a file the format list knows")
    func fileNamesMatchTheSetting() async throws {
        for format in AudioArchiveFormat.allCases {
            let folder = try Folder()
            try Self.writeWAV(to: folder.audio, frequencies: [440], seconds: 1)
            let result = try await AudioTranscoder.archive(wav: folder.audio, as: format, in: folder.url)
            // `meta.audio` must name a file that is actually there — a reader that
            // trusts the field and finds nothing is worse off than one told the truth.
            #expect(folder.exists(result.fileName))
            #expect(
                AudioArchiveFormat.allCases.map(\.audioFileName).contains(result.fileName),
                "\(result.fileName) is not one of the documented archive names"
            )
        }
    }
}
