import Foundation
import StenoCore

/// Why a recording ended without anyone asking it to.
///
/// All three end the same way — the recording stops, `meta.json` reads `failed` with
/// `error`, and the menu says what happened — but they are kept apart because the
/// sentence the user reads is different, and because a lost device is worth telling
/// apart from a full disk when a recording is missing afterwards.
enum AudioInterruptionReason: Sendable, Equatable {
    /// The input device went away and did not come back. The plan's device-loss case.
    case inputDeviceLost(device: String)
    /// The engine stopped and would not restart — a sample-rate change that could not
    /// be followed, or a device that refused to open again.
    case captureStopped(String)
    /// Writing to `audio.wav` failed. A full volume is the case that matters.
    case writeFailed(String)

    /// The sentence the menu shows and `meta.error` records.
    var localizedReason: String {
        switch self {
        case .inputDeviceLost(let device):
            return String(
                format: String(localized: "Das Eingabegerät „%@“ ist verschwunden. Die Aufnahme wurde beendet."),
                device
            )
        case .captureStopped(let detail):
            return String(
                format: String(localized: "Die Aufnahme wurde vom System beendet: %@"),
                detail
            )
        case .writeFailed(let detail):
            return String(
                format: String(localized: "Die Audiodatei ließ sich nicht schreiben: %@"),
                detail
            )
        }
    }
}

/// What a recorder needs to know to start.
struct AudioRecorderConfiguration: Sendable {
    var mode: MeetingMode
    /// The meeting folder. A recorder writes `audio.wav` and nothing else into it.
    var folder: URL
    /// `AVCaptureDevice.uniqueID` of the input to use, or `nil` for the system default.
    var inputDeviceUID: String?
    /// When the recording started, so that timestamps line up with `meta.json`.
    var started: Date
    /// Called at most once, from whatever thread noticed, when capture ends by itself.
    ///
    /// Carried in the configuration rather than added to the protocol so that both
    /// recorders and every test double get it for free, and so a recorder never has to
    /// hold main-actor state to reach the coordinator: the closure the coordinator
    /// installs is the only thing that hops back.
    var onInterruption: (@Sendable (AudioInterruptionReason) -> Void)?
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
    /// Length of the audio file, derived from the frames rather than from the clock.
    ///
    /// The wall-clock duration in `meta.json` covers the whole recording including the
    /// hardware handshake at both ends; this one covers the samples. They differ by a
    /// few tens of milliseconds, and a large gap between them is the sign of dropped
    /// buffers.
    var duration: TimeInterval?
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

/// Which recorder a mode gets.
///
/// The two modes capture in completely different ways — `AVAudioEngine` for `onsite`
/// (specification §3b), a process tap plus an aggregate device for `online` (§3a) —
/// and a recorder is opened per recording rather than held for the life of the app,
/// because holding a microphone open between meetings is both wasteful and visible in
/// the menu bar's orange dot. So the coordinator asks for one when it needs one.
protocol RecorderFactory: Sendable {
    func recorder(for mode: MeetingMode) -> any AudioRecorder
}

/// The real thing: `MicRecorder` for `onsite`, and `NullRecorder` for `online` until
/// M2 lands the tap.
struct DefaultRecorderFactory: RecorderFactory {
    func recorder(for mode: MeetingMode) -> any AudioRecorder {
        switch mode {
        case .onsite:
            return MicRecorder()
        case .online:
            return NullRecorder()
        }
    }
}

/// One recorder for every mode. What the tests inject, and what `--simulate-null-recording`
/// uses.
struct FixedRecorderFactory: RecorderFactory {
    let fixed: any AudioRecorder

    init(_ fixed: any AudioRecorder) {
        self.fixed = fixed
    }

    func recorder(for mode: MeetingMode) -> any AudioRecorder { fixed }
}
