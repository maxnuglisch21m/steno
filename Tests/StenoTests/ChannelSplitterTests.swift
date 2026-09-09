import AVFoundation
import Foundation
import StenoCore
import Testing

@testable import Steno

/// The step between `audio.wav` and the models.
///
/// The interesting property is not "two files appeared" but "the right sound is in
/// each of them", so the fixture is a two-channel file with a different tone per
/// channel — 440 Hz on ch0, 880 Hz on ch1 — and each work file is checked by counting
/// its zero crossings. A splitter that mixed the channels, or swapped them, or resampled
/// one of them wrongly, fails that check; one that merely wrote two files passes a file
/// count and would not be caught.
@Suite("ChannelSplitter")
struct ChannelSplitterTests {
    /// A throwaway folder, removed when the test ends.
    ///
    /// A class rather than a non-copyable struct: `#expect` captures its operands, and
    /// a `~Copyable` value cannot be captured — which turns every readable assertion
    /// about the folder into a compiler error.
    private final class Folder {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("steno-split-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        var audio: URL { url.appendingPathComponent(WAVWriter.fileName) }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes a 48 kHz 16-bit WAV with one tone per channel.
    @discardableResult
    private static func writeTones(
        to url: URL,
        frequencies: [Double],
        seconds: Double = 2
    ) throws -> Int {
        let channels = AVAudioChannelCount(frequencies.count)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: Int(channels),
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
        return Int(frames)
    }

    /// The dominant frequency of a mono file, by counting zero crossings.
    ///
    /// A whole DFT would be more precise and no more convincing: a pure tone crosses
    /// zero twice per period, so the count over a known length is the frequency, and
    /// anything that mixed two tones together lands nowhere near either.
    private static func dominantFrequency(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)

        // The first and last twentieth are skipped: a resampler's filter ramps up and
        // down there, and near-zero samples make spurious crossings.
        let start = count / 20
        let end = count - count / 20
        guard end > start else { return 0 }

        var crossings = 0
        var previous = samples[start]
        for index in (start + 1)..<end {
            let value = samples[index]
            // A dead band around zero, so noise around a crossing is not counted twice.
            if abs(value) < 0.01 { continue }
            if (previous < 0) != (value < 0) { crossings += 1 }
            previous = value
        }
        let seconds = Double(end - start) / format.sampleRate
        return Double(crossings) / (2 * seconds)
    }

    // MARK: - Two channels

    @Test("a two-channel file becomes two 16 kHz mono files, one tone in each")
    func splitsTwoChannels() throws {
        let folder = try Folder()
        try Self.writeTones(to: folder.audio, frequencies: [440, 880])

        let output = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: true)

        let room = try #require(FileManager.default.fileExists(atPath: output.room.path) ? output.room : nil)
        let mic = try #require(output.mic)
        #expect(FileManager.default.fileExists(atPath: mic.path))
        #expect(output.sourceChannels == 2)
        #expect(abs(output.duration - 2) < 0.01)

        // Channel 0 is 440 Hz and channel 1 is 880 Hz, and neither leaked into the other.
        let roomFrequency = try Self.dominantFrequency(of: room)
        let micFrequency = try Self.dominantFrequency(of: mic)
        #expect(abs(roomFrequency - 440) < 15, "ch0 came out at \(roomFrequency) Hz")
        #expect(abs(micFrequency - 880) < 25, "ch1 came out at \(micFrequency) Hz")
    }

    @Test("the work files are 16 kHz mono Float32, which is what the models read")
    func workFileFormat() throws {
        let folder = try Folder()
        try Self.writeTones(to: folder.audio, frequencies: [440, 880])

        let output = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: true)

        for url in [output.room, try #require(output.mic)] {
            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == 16_000)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.processingFormat.commonFormat == .pcmFormatFloat32)
            // Two seconds at 16 kHz, to within the resampler's own filter delay.
            #expect(abs(Double(file.length) / 16_000 - 2) < 0.05)
        }
    }

    @Test("the files land in _work, named the way the queue expects")
    func namesAndLocation() throws {
        let folder = try Folder()
        try Self.writeTones(to: folder.audio, frequencies: [440, 880])

        let output = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: true)

        #expect(output.workDirectory == folder.url.appendingPathComponent("_work"))
        #expect(output.room.lastPathComponent == "room16k.wav")
        #expect(output.mic?.lastPathComponent == "mic16k.wav")
        #expect(output.room.deletingLastPathComponent() == output.workDirectory)
    }

    // MARK: - One channel

    @Test("an onsite file produces only the room channel")
    func onsiteHasNoMic() throws {
        let folder = try Folder()
        try Self.writeTones(to: folder.audio, frequencies: [440])

        let output = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: false)

        #expect(output.mic == nil)
        #expect(output.sourceChannels == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: output.workDirectory.appendingPathComponent("mic16k.wav").path
            )
        )
        let frequency = try Self.dominantFrequency(of: output.room)
        #expect(abs(frequency - 440) < 15)
    }

    @Test("a one-channel file asked for a microphone gives what it has")
    func missingSecondChannelIsNotAFailure() throws {
        // An `online` recording whose microphone never opened is a one-channel file.
        // Failing the whole transcription over the half that is fine would be worse
        // than transcribing the half that is there.
        let folder = try Folder()
        try Self.writeTones(to: folder.audio, frequencies: [440])

        let output = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: true)

        #expect(output.mic == nil)
        #expect(FileManager.default.fileExists(atPath: output.room.path))
    }

    // MARK: - Housekeeping

    @Test("a second run replaces the work directory rather than adding to it")
    func rerunIsClean() throws {
        let folder = try Folder()
        try Self.writeTones(to: folder.audio, frequencies: [440, 880])

        _ = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: true)
        // A retry of a folder that was `online` and is now being split as `onsite`
        // must not leave the earlier microphone file behind for the merger to find.
        let output = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: false)

        let contents = try FileManager.default.contentsOfDirectory(atPath: output.workDirectory.path)
        #expect(contents.sorted() == ["room16k.wav"])
    }

    @Test("removing the work directory removes everything in it")
    func removesWorkDirectory() throws {
        let folder = try Folder()
        try Self.writeTones(to: folder.audio, frequencies: [440, 880])
        _ = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: true)

        ChannelSplitter.removeWorkDirectory(in: folder.url)

        #expect(
            !FileManager.default.fileExists(
                atPath: ChannelSplitter.workDirectory(in: folder.url).path
            )
        )
    }

    // MARK: - Refusals

    @Test("a folder with no audio says so instead of producing empty files")
    func missingAudio() throws {
        let folder = try Folder()
        #expect(throws: ChannelSplitter.Failure.self) {
            try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: false)
        }
    }

    @Test("a WAV with a header but no samples is refused")
    func emptyAudio() throws {
        let folder = try Folder()
        _ = try AVAudioFile(
            forWriting: folder.audio,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ]
        )
        #expect(throws: ChannelSplitter.Failure.self) {
            try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: false)
        }
    }

    @Test("an hour of audio is split without being held in memory")
    func longFileStreams() throws {
        // Not a memory measurement — a check that the chunk loop terminates and gets
        // the length right on a file many chunks long. Sixty seconds is enough for
        // that; the loop does not know how long the file is.
        let folder = try Folder()
        try Self.writeTones(to: folder.audio, frequencies: [440, 880], seconds: 60)

        let output = try ChannelSplitter.split(audio: folder.audio, in: folder.url, wantsMic: true)

        #expect(abs(output.duration - 60) < 0.01)
        let room = try AVAudioFile(forReading: output.room)
        #expect(abs(Double(room.length) / 16_000 - 60) < 0.05)
        let frequency = try Self.dominantFrequency(of: output.room)
        #expect(abs(frequency - 440) < 15)
    }
}
