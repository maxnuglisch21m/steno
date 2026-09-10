import Foundation

/// Which of the two recording modes a meeting used. Everything else — channel count,
/// speaker attribution, and how a recording may start and stop — follows from it.
public enum MeetingMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Teams, Zoom, Meet: two channels, system audio plus microphone.
    case online
    /// A meeting in a room: one channel from the room microphone.
    case onsite

    /// The channels a recording in this mode writes, in channel order.
    public var channels: [MeetingChannel] {
        switch self {
        case .online: return [.system, .mic]
        case .onsite: return [.room]
        }
    }

    /// Whether the speaker `ME` can be identified. Only `online` has a physically
    /// separate microphone track to anchor it to.
    public var supportsSelfSpeaker: Bool { self == .online }
}

/// One channel of `audio.wav`, in the order it appears in the file.
public enum MeetingChannel: String, Codable, Sendable, Hashable, CaseIterable {
    /// The room microphone of an `onsite` recording — channel 0.
    case room
    /// The tapped system audio of an `online` recording, downmixed to mono — channel 0.
    case system
    /// The microphone of an `online` recording — channel 1.
    case mic
}

/// How the recording was started.
public struct MeetingTrigger: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// Started from the menu or a hotkey.
        case manual
        /// Started from the suggestion popup or an `always` rule, after detection fired.
        case auto
    }

    public var kind: Kind
    /// Bundle identifier of the app whose microphone use triggered detection.
    public var bundleId: String?
    /// Display name of that app, as shown in the popup and used in the folder name.
    public var name: String?

    public init(kind: Kind, bundleId: String? = nil, name: String? = nil) {
        self.kind = kind
        self.bundleId = bundleId
        self.name = name
    }

    public static let manual = MeetingTrigger(kind: .manual)

    public static func auto(bundleId: String, name: String) -> MeetingTrigger {
        MeetingTrigger(kind: .auto, bundleId: bundleId, name: name)
    }
}

/// Why capture ended.
///
/// A recording that stopped because the meeting ended, one the user stopped, and one
/// the Mac cut short by going to sleep all leave the same files behind, and only this
/// field tells them apart afterwards. It says nothing about success: a recording can
/// end for any of these reasons and still be `done`, and `stopReason` is written even
/// when `state` ends up `failed`, where `error` says what went wrong and this says
/// what ended it.
public enum MeetingStopReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// The user pressed stop, in the menu or with ⌥⌘S.
    case manual
    /// Detection saw no watched process reading the microphone for long enough.
    /// Specification §2's auto-stop. `online` only.
    case auto
    /// The Mac went to sleep. The recording was closed before the machine suspended.
    case sleep
    /// The input device disappeared, or capture was ended by the system.
    case deviceLost
    /// Nothing ended it: the app died mid-recording and the folder was finished by the
    /// recovery scan on the next launch.
    ///
    /// Written by nobody who was there — a crash leaves no code running to record
    /// anything — so it is set afterwards, from the outside, by the pass that repairs
    /// the WAV header and derives `ended` from the newest file's modification time.
    /// It is therefore the one stop reason whose `ended` is an inference rather than an
    /// observation, and the one that says the audio may be a second or two short of
    /// what the meeting actually was.
    case crash
}

/// The audio input the recording used, and the microphone mode it was in.
///
/// `microphoneMode` matters for `onsite`: macOS Voice Isolation suppresses every
/// voice but the closest one, so a recording made in that mode is worth distrusting
/// even though Steno refuses to start one.
public struct AudioInputInfo: Codable, Sendable, Hashable {
    public var device: String
    public var microphoneMode: String?

    public init(device: String, microphoneMode: String? = nil) {
        self.device = device
        self.microphoneMode = microphoneMode
    }
}

/// What the user said about how many people are in the room.
///
/// Diarization finds the speaker count on its own, and usually well enough — but on
/// room audio it is the hardest part of the job (specification §9), and the offline
/// diarizer accepts a bound. So `onsite` may ask before it starts (specification §3b,
/// off by default), and the answer is carried here to be fed into the diarizer's
/// `clustering.minSpeakers` and `maxSpeakers` when transcription runs.
///
/// It is a hint, not a measurement: nothing downstream may treat `expected` as the
/// number of speakers the transcript actually has.
public struct SpeakerHint: Codable, Sendable, Hashable {
    /// How many people the user expects, or `nil` for "let the diarizer decide".
    public var expected: Int?

    /// The range the picker offers, and the range `expected` is kept inside.
    ///
    /// One speaker needs no diarization and more than eight in one room is past the
    /// point where a single microphone separates anything, so a value outside this is
    /// a bug rather than a preference and is dropped instead of narrowing the
    /// diarizer to nonsense.
    public static let allowedRange = 2...8

    public init(expected: Int?) {
        self.expected = expected.flatMap { Self.allowedRange.contains($0) ? $0 : nil }
    }

    /// Whether this hint says anything at all. An empty hint is not written out.
    public var isEmpty: Bool { expected == nil }
}

/// A display that was being captured, in the order the screenshot file names use.
public struct DisplayInfo: Codable, Sendable, Hashable {
    /// Index used in screenshot file names — the `1` in `143012_d1_active.jpg`.
    public var index: Int
    /// `CGDirectDisplayID` at recording time. Not stable across reboots.
    public var id: UInt32
    /// Pixel dimensions, `[width, height]`, before any capture downscaling.
    public var px: [Int]

    public init(index: Int, id: UInt32, px: [Int]) {
        self.index = index
        self.id = id
        self.px = px
    }

    public init(index: Int, id: UInt32, width: Int, height: Int) {
        self.init(index: index, id: id, px: [width, height])
    }

    public var width: Int? { px.count == 2 ? px[0] : nil }
    public var height: Int? { px.count == 2 ? px[1] : nil }
}

/// `meta.json`: everything about one recording that is not audio, image, or text.
///
/// The shape follows the specification §6 exactly, plus the fields the plan adds:
/// `title`, `audio`, `appBuild`, `os`, `models`, and `error`. Every added field is
/// optional, so a reader written against the specification keeps working.
public struct MeetingMeta: Codable, Sendable, Hashable {
    // Specification §6
    public var mode: MeetingMode
    public var started: Date
    public var ended: Date?
    /// Recording length in seconds. `nil` while still recording.
    public var duration: TimeInterval?
    public var trigger: MeetingTrigger
    public var channels: [MeetingChannel]
    public var input: AudioInputInfo
    public var displays: [DisplayInfo]
    /// Number of screenshots written, i.e. lines in `screens.jsonl`.
    public var screenshots: Int
    /// Steno's marketing version, `CFBundleShortVersionString`.
    public var app: String
    public var state: MeetingState

    // Additions
    /// Meeting title from the triggering app's window or a calendar event, if known.
    public var title: String?
    /// File name of the audio archive — `audio.m4a`, `audio.flac`, or `audio.wav`.
    public var audio: String?
    /// Steno's build number, `CFBundleVersion`.
    public var appBuild: String?
    /// macOS version the recording was made on.
    public var os: String?
    /// Models used for the transcript. Written when transcription finishes.
    public var models: ModelIdentifiers?
    /// Why the recording ended in `failed`. Written together with that state.
    public var error: String?
    /// What the user said about the number of people in the room, if asked.
    /// Absent whenever nothing was said, which is the default.
    public var speakers: SpeakerHint?
    /// What ended the capture. Absent while `state` is `recording`, and absent for a
    /// recording that was interrupted before anything could be said about it.
    public var stopReason: MeetingStopReason?

    public init(
        mode: MeetingMode,
        started: Date,
        ended: Date? = nil,
        duration: TimeInterval? = nil,
        trigger: MeetingTrigger,
        channels: [MeetingChannel]? = nil,
        input: AudioInputInfo,
        displays: [DisplayInfo] = [],
        screenshots: Int = 0,
        app: String,
        state: MeetingState = .recording,
        title: String? = nil,
        audio: String? = nil,
        appBuild: String? = nil,
        os: String? = nil,
        models: ModelIdentifiers? = nil,
        error: String? = nil,
        speakers: SpeakerHint? = nil,
        stopReason: MeetingStopReason? = nil
    ) {
        self.mode = mode
        self.started = started
        self.ended = ended
        self.duration = duration
        self.trigger = trigger
        self.channels = channels ?? mode.channels
        self.input = input
        self.displays = displays
        self.screenshots = screenshots
        self.app = app
        self.state = state
        self.title = title
        self.audio = audio
        self.appBuild = appBuild
        self.os = os
        self.models = models
        self.error = error
        // An empty hint is the same as no hint, and writing `"speakers":{}` into every
        // `meta.json` would put a key in the format that says nothing.
        self.speakers = speakers.flatMap { $0.isEmpty ? nil : $0 }
        self.stopReason = stopReason
    }

    // MARK: - State

    /// Advances `state`, throwing on a transition that is not part of the lifecycle.
    public mutating func transition(to next: MeetingState) throws {
        try state.transition(to: next)
    }

    /// Marks the recording failed with a reason, throwing if `failed` is unreachable
    /// from the current state.
    public mutating func fail(reason: String) throws {
        try state.transition(to: .failed)
        error = reason
    }

    /// Sets `ended` and derives `duration` from it, and records what ended it.
    ///
    /// The reason is optional so that a caller with nothing to say does not have to
    /// invent one; passing `nil` leaves whatever was already there, so a stop reason
    /// recorded by the path that noticed first is not overwritten by a later,
    /// less-informed writer.
    public mutating func finishCapture(at end: Date, reason: MeetingStopReason? = nil) {
        ended = end
        duration = end.timeIntervalSince(started)
        if let reason { stopReason = reason }
    }

    /// Records the speaker count the user gave, or clears the hint.
    ///
    /// Goes through `SpeakerHint`, so a count outside the allowed range and a `nil`
    /// both end as no key at all rather than as a hint that means nothing.
    public mutating func setExpectedSpeakers(_ count: Int?) {
        let hint = SpeakerHint(expected: count)
        speakers = hint.isEmpty ? nil : hint
    }

    // MARK: - Coding

    /// An encoder that writes dates as ISO-8601 with a numeric time-zone offset, as
    /// `"2026-09-09T14:30:12+02:00"` — not as the `Z`-suffixed UTC form that
    /// `JSONEncoder.DateEncodingStrategy.iso8601` produces, because the local wall
    /// clock is what makes a `meta.json` readable next to a folder name.
    ///
    /// Keys are sorted and the output is pretty-printed: `meta.json` is rewritten on
    /// every state change, and a stable key order keeps those rewrites diffable.
    public static func encoder(timeZone: TimeZone = .current) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(style.format(date))
        }
        return encoder
    }

    /// A decoder for the format `encoder(timeZone:)` writes. The offset carried by the
    /// string wins, so a recording made in a different zone decodes to the right instant.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601Timestamp.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "\"\(string)\" is not an ISO-8601 timestamp"
                )
            }
            return date
        }
        return decoder
    }

    public func jsonData(timeZone: TimeZone = .current) throws -> Data {
        try Self.encoder(timeZone: timeZone).encode(self)
    }

    public static func decode(from data: Data) throws -> MeetingMeta {
        try decoder().decode(MeetingMeta.self, from: data)
    }
}

/// Reads and writes the ISO-8601 timestamps that `meta.json` and the transcript use.
public enum ISO8601Timestamp {
    /// `2026-09-09T14:30:12+02:00`, or `…Z` when `timeZone` is UTC.
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone).format(date)
    }

    /// Parses an ISO-8601 timestamp, honouring the offset in the string. Fractional
    /// seconds are accepted. Returns `nil` for anything unparseable.
    public static func date(from string: String) -> Date? {
        // The style's own time zone only applies to strings that carry no offset; the
        // offset in the string takes precedence when it has one.
        let style = Date.ISO8601FormatStyle(
            timeZoneSeparator: .colon,
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )
        return try? Date(string, strategy: style)
    }
}
