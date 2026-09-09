import OSLog

/// The app's loggers, one per area of the code.
///
/// Everything goes through `os.Logger` rather than `print`, so that a recording that
/// misbehaved can be reconstructed afterwards from the unified log — Steno has no
/// crash reporting and no analytics, and this is deliberately the only trace it
/// leaves. Categories match the source directories, so
/// `log stream --predicate 'subsystem == "de.21m.steno" && category == "audio"'`
/// shows exactly the audio path.
///
/// Nothing recorded here may contain meeting content: no transcript text, no window
/// titles, no file names of screenshots. Paths and durations, yes; what was said, no.
enum Log {
    static let subsystem = "de.21m.steno"

    /// Lifecycle, menu, hotkeys, permissions, settings.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Process taps, aggregate devices, the microphone, WAV writing.
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// Meeting detection, window and calendar titles, rules.
    static let detection = Logger(subsystem: subsystem, category: "detection")
    /// ScreenCaptureKit streams and the screenshot gate.
    static let screens = Logger(subsystem: subsystem, category: "screens")
    /// ASR, diarization, merging, and model downloads.
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    /// The recording root, meeting folders, `meta.json`, disk space.
    static let storage = Logger(subsystem: subsystem, category: "storage")
}
