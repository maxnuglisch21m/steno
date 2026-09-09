import Foundation
import StenoCore

/// What a recorder needs to know to start.
struct AudioRecorderConfiguration: Sendable {
    var mode: MeetingMode
    /// The meeting folder. A recorder writes `audio.wav` and nothing else into it.
    var folder: URL
    /// `AVCaptureDevice.uniqueID` of the input to use, or `nil` for the system default.
    var inputDeviceUID: String?
    /// When the recording started, so that timestamps line up with `meta.json`.
    var started: Date
}

/// What a recorder reports once it has actually opened the hardware.
struct AudioRecorderStart: Sendable {
    /// Human-readable name of the device that ended up being used, for `meta.json`.
    var deviceName: String
    /// `AVCaptureDevice.activeMicrophoneMode` as a string, for `meta.json`.
    var microphoneMode: String?
}

/// What a recorder leaves behind.
struct AudioRecorderOutcome: Sendable {
    /// Name of the audio file inside the meeting folder, or `nil` when nothing was
    /// written — which is what M0's `NullRecorder` reports.
    var audioFileName: String?
    /// The channels actually captured. The coordinator compares them with the mode's.
    var channels: [MeetingChannel]
    /// Frames written, for a sanity check against the wall-clock duration.
    var frameCount: Int64?
}

/// The one thing the recording flow needs from the audio layer.
///
/// Declared in M0 so that the menu, the coordinator, and `meta.json` can be built and
/// tested before any hardware is touched. `MicRecorder` (M1, `AVAudioEngine`) and
/// `ProcessTapRecorder` (M2, Core Audio tap plus aggregate device) implement it; both
/// will be actors, which is why the requirements are `async` even though M0's
/// implementation does no waiting.
protocol AudioRecorder: Sendable {
    /// Opens the input and begins writing. Throws if the hardware refuses.
    func start(_ configuration: AudioRecorderConfiguration) async throws -> AudioRecorderStart
    /// Stops writing and closes the file. Safe to call when not recording.
    func stop() async throws -> AudioRecorderOutcome
}

/// A recorder that records nothing.
///
/// It exists so the whole flow around the audio — folder creation, `meta.json` and its
/// state machine, the menu-bar icon, the hotkeys, the disk-space check — is real,
/// exercised, and testable in M0, with the actual capture dropped in behind the same
/// protocol in M1 and M2. `--simulate-recording` runs through exactly this path.
actor NullRecorder: AudioRecorder {
    private var configuration: AudioRecorderConfiguration?

    init() {}

    func start(_ configuration: AudioRecorderConfiguration) async throws -> AudioRecorderStart {
        self.configuration = configuration
        Log.audio.notice(
            "NullRecorder started for \(configuration.mode.rawValue, privacy: .public) — no audio is being written (M1/M2)"
        )
        return AudioRecorderStart(
            deviceName: AudioInputDevices.displayName(forUID: configuration.inputDeviceUID),
            microphoneMode: nil
        )
    }

    func stop() async throws -> AudioRecorderOutcome {
        let mode = configuration?.mode ?? .onsite
        configuration = nil
        Log.audio.notice("NullRecorder stopped")
        // The channels are the mode's, so that `meta.json` describes what a real
        // recorder would have produced; `audioFileName` stays nil because no file was
        // written and claiming one would be a lie a downstream tool would trip over.
        return AudioRecorderOutcome(audioFileName: nil, channels: mode.channels, frameCount: nil)
    }
}
