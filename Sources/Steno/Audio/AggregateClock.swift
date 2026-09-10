import Foundation

/// Which member of the `online` aggregate device sets the clock, and which one is
/// resampled onto it.
///
/// An aggregate device runs at the rate of its **main sub-device**, and every other
/// member is drift-compensated onto that rate. Until the first real Teams meeting the
/// microphone was always the main sub-device, on the reasoning that real hardware with
/// a real crystal should lead and a software tap should follow.
///
/// That reasoning holds for a microphone that runs at 48 kHz. It does not hold for a
/// Bluetooth headset. A Poly BT700 in a call switches to its hands-free profile and
/// runs the input at **16 kHz**, the aggregate then refuses 48 kHz — "the aggregate
/// device refused 48 kHz; recording at its own rate and converting" is the line that
/// appeared in the log — and the tap's 48 kHz system audio is downsampled to 16 kHz
/// before Steno ever sees it. `WAVWriter` dutifully converts the result back up to
/// 48 kHz, so `audio.wav` looks right and channel 0 has lost everything above 8 kHz
/// for good. It is audible, and the recognizer's German fell apart at the point in
/// that recording where the headset took over.
///
/// So the choice is made by the numbers rather than by the principle:
///
/// - **Microphone at 48 kHz or more** — it leads, as before. Nothing is resampled that
///   was not resampled before, and the arrangement that has been recording correctly
///   is left alone.
/// - **Microphone below 48 kHz** — the tap leads. The tap is created from the tapped
///   app's own output format, which on this Mac is 48 kHz, so the aggregate keeps the
///   rate the file is written at; the headset's 16 kHz is drift-compensated up to it,
///   which loses nothing that was ever there. A 16 kHz microphone channel resampled to
///   48 kHz is exactly as good as a 16 kHz microphone channel, and channel 0 stops
///   being collateral damage.
///
/// The whole decision is this one function, so that it can be checked without a
/// Bluetooth headset in the room.
enum AggregateClock {
    /// Which sub-device the aggregate should be built around.
    enum Master: String, Sendable, Equatable {
        /// The microphone leads and the tap is drift-compensated onto it.
        case microphone
        /// The tap leads and the microphone is drift-compensated onto it.
        case tap

        /// For the log line, which is the only place this is visible from outside.
        var logDescription: String {
            switch self {
            case .microphone: return "mic is the clock"
            case .tap: return "tap is the clock"
            }
        }
    }

    /// The rate the recording is written at, and the rate a tap runs at on this Mac.
    static let targetSampleRate: Double = 48_000

    /// Who leads, given what the microphone says its nominal rate is.
    ///
    /// - Parameter micSampleRate: `kAudioDevicePropertyNominalSampleRate` of the input
    ///   device. A rate of zero or less means the device would not answer, and the
    ///   microphone keeps the lead — an unknown rate is not evidence of a slow one, and
    ///   changing the arrangement on no evidence is how a working recording breaks.
    static func master(micSampleRate: Double, target: Double = targetSampleRate) -> Master {
        guard micSampleRate > 0 else { return .microphone }
        return micSampleRate < target ? .tap : .microphone
    }
}
