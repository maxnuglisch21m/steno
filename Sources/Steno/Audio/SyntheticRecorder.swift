#if DEBUG
import AVFoundation
import Foundation
import StenoCore

/// A recorder that produces a known test signal without touching any hardware.
///
/// It exists for one thing that could not be verified any other way: M6's crash
/// recovery. Proving that an interrupted recording is repaired needs a recording that
/// is actually interrupted — a process that dies mid-write, leaving a WAV whose header
/// still claims zero bytes, a `meta.json` still saying `recording`, and a `.steno-lock`
/// nobody removed. Killing a real recording to arrange that is not an option on a Mac
/// somebody is using: a process killed inside `AudioDeviceStart` leaves a tap behind in
/// `coreaudiod`, and every recording after it hangs until the machine is restarted.
///
/// So this writes through the real `WAVWriter` — the same file, the same format, the
/// same header — with samples it generates itself, and dies on command from a place
/// where there is no hardware to leave behind. Everything downstream of the samples is
/// the real thing, which is what makes the crash test worth running.
///
/// The signal is a sine per channel: 440 Hz on channel 0 (the room, or the tapped
/// meeting audio), 880 Hz on channel 1 (the microphone of an `online` recording). Two
/// different tones so that a channel swap is audible and measurable rather than
/// invisible, and pure tones so that `afinfo` and a spectrum both say plainly what the
/// file should hold. It transcribes to nothing, which is fine: what is being tested is
/// the state machine and the files, not the words.
actor SyntheticRecorder: AudioRecorder {
    /// Channel 0 — the room, or the meeting.
    static let roomFrequency: Double = 440
    /// Channel 1 — the microphone, `online` only.
    static let micFrequency: Double = 880

    /// How much audio is generated per buffer. A tenth of a second is roughly what a
    /// real tap delivers and keeps the crash point accurate to within one buffer.
    private static let bufferDuration: TimeInterval = 0.1

    /// Seconds of audio after which the process calls `_exit(0)`.
    ///
    /// Counted in written frames rather than on the wall clock, so the crash lands at a
    /// known point in the recording every time. `_exit` rather than `exit` or
    /// `NSApp.terminate`: no atexit handlers, no `applicationWillTerminate`, no
    /// `AVAudioFile` deinit — nothing that would close the file properly, which is
    /// precisely the state a crash leaves and the state the recovery pass has to cope
    /// with.
    private let crashAfter: TimeInterval?

    private var writer: WAVWriter?
    private var generator: Task<Void, Never>?
    private var configuration: AudioRecorderConfiguration?

    init(crashAfter: TimeInterval? = nil) {
        self.crashAfter = crashAfter
    }

    // MARK: - AudioRecorder

    func start(_ configuration: AudioRecorderConfiguration) async throws -> AudioRecorderStart {
        let channelCount = configuration.mode.channels.count
        let onInterruption = configuration.onInterruption
        let opened = try WAVWriter(
            folder: configuration.folder,
            channelCount: channelCount,
            onError: { error in
                onInterruption?(.writeFailed(error.localizedDescription))
            }
        )
        writer = opened
        self.configuration = configuration

        let tones = channelCount > 1 ? "440/880 Hz" : "440 Hz"
        let crash = crashAfter.map { ", crashing after \(Int($0)) s" } ?? ""
        Log.audio.notice(
            "synthetic recorder started: \(channelCount, privacy: .public) ch, \(tones, privacy: .public)\(crash, privacy: .public)"
        )

        let crashAfter = self.crashAfter
        generator = Task.detached(priority: .userInitiated) { [opened] in
            await Self.generate(into: opened, channels: channelCount, crashAfter: crashAfter)
        }

        return AudioRecorderStart(deviceName: "Synthetic 440/880 Hz", microphoneMode: nil)
    }

    func stop() async throws -> AudioRecorderOutcome {
        generator?.cancel()
        generator = nil
        let mode = configuration?.mode ?? .onsite
        configuration = nil

        guard let writer else {
            return AudioRecorderOutcome(audioFileName: nil, channels: mode.channels)
        }
        self.writer = nil
        let result = writer.close()
        Log.audio.notice("synthetic recorder stopped")
        return AudioRecorderOutcome(
            audioFileName: result.fileName,
            channels: mode.channels,
            frameCount: result.frameCount,
            duration: result.duration
        )
    }

    // MARK: - The signal

    /// Fills buffers with sine waves and hands them to the writer until cancelled.
    ///
    /// Paced against a monotonic clock so that a recording of twelve seconds holds
    /// twelve seconds of audio: generating as fast as the CPU allows would write an
    /// hour in a moment and make every duration in `meta.json` a lie.
    private static func generate(
        into writer: WAVWriter,
        channels: Int,
        crashAfter: TimeInterval?
    ) async {
        let sampleRate = WAVWriter.sampleRate
        let framesPerBuffer = AVAudioFrameCount(sampleRate * bufferDuration)
        var phase0 = 0.0
        var phase1 = 0.0
        let step0 = 2 * Double.pi * roomFrequency / sampleRate
        let step1 = 2 * Double.pi * micFrequency / sampleRate
        var framesWritten: Int64 = 0
        let started = ContinuousClock.now

        while !Task.isCancelled {
            guard
                let buffer = AVAudioPCMBuffer(pcmFormat: writer.format, frameCapacity: framesPerBuffer),
                let samples = buffer.int16ChannelData?[0]
            else {
                Log.audio.error("synthetic recorder could not allocate a buffer")
                return
            }
            buffer.frameLength = framesPerBuffer

            // Interleaved Int16, which is what `WAVWriter.format` is, so nothing is
            // converted on the way to the file.
            let amplitude = 0.5 * Double(Int16.max)
            for frame in 0..<Int(framesPerBuffer) {
                samples[frame * channels] = Int16(amplitude * sin(phase0))
                if channels > 1 {
                    samples[frame * channels + 1] = Int16(amplitude * sin(phase1))
                }
                phase0 += step0
                phase1 += step1
            }
            phase0.formTruncatingRemainder(dividingBy: 2 * .pi)
            phase1.formTruncatingRemainder(dividingBy: 2 * .pi)

            writer.write(buffer)
            framesWritten += Int64(framesPerBuffer)

            if let crashAfter, Double(framesWritten) / sampleRate >= crashAfter {
                await crash(after: framesWritten, sampleRate: sampleRate)
            }

            // Where this buffer's audio ends, in wall-clock terms, minus where we are.
            let target = started.advanced(by: .seconds(Double(framesWritten) / sampleRate))
            let remaining = ContinuousClock.now.duration(to: target)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
    }

    /// Dies the way a crash does, and says so first.
    private static func crash(after frames: Int64, sampleRate: Double) async {
        let seconds = Double(frames) / sampleRate
        let line = """
        steno-debug: synthetic recorder crashing after \
        \(String(format: "%.1f", seconds)) s of audio, without closing anything

        """
        Log.audio.error("debug: \(line, privacy: .public)")
        FileHandle.standardError.write(Data(line.utf8))
        // The writer's own queue is asynchronous, so the last buffers handed over are
        // still in flight. A moment for them to reach the disk makes the crash land in
        // the middle of the file rather than in the middle of the hand-over, which is
        // the case worth testing — the header is stale either way.
        try? await Task.sleep(for: .milliseconds(200))
        _exit(0)
    }
}
#endif
