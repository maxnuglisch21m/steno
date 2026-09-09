import Foundation

/// The models a transcript was produced with, as written to both `transcript.json`
/// and `meta.json`.
public struct ModelIdentifiers: Codable, Sendable, Hashable {
    public var asr: String
    public var diarizer: String

    public init(asr: String, diarizer: String) {
        self.asr = asr
        self.diarizer = diarizer
    }
}

/// A word with the time it starts, as it appears inside an utterance in
/// `transcript.json`: `{"t":12.30,"w":"Also"}`.
public struct Token: Codable, Sendable, Hashable {
    /// Start time in seconds from the beginning of the recording.
    public var t: TimeInterval
    /// The word.
    public var w: String

    public init(t: TimeInterval, w: String) {
        self.t = t
        self.w = w
    }
}

/// One continuous stretch of speech by one speaker.
public struct Utterance: Codable, Sendable, Hashable {
    /// `ME`, `S1`…`Sn`, or `UNKNOWN`.
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var tokens: [Token]

    public init(
        speaker: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        tokens: [Token]
    ) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.tokens = tokens
    }

    public var duration: TimeInterval { end - start }
}

/// One raw segment as the diarizer produced it, before any merging.
///
/// These are kept in `transcript.json` on purpose. Diarization error rate runs around
/// 18–20 % on room audio, so speaker labels are suggestions; a reader that can see
/// the raw segments can judge them instead of trusting a smoothed-over guess.
public struct DiarSegment: Codable, Sendable, Hashable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }

    /// Whether this segment covers an instant. Half-open, so segments that abut do not
    /// both claim the boundary.
    public func covers(_ time: TimeInterval) -> Bool {
        start <= time && time < end
    }
}

/// `transcript.json` — the machine-readable truth about one meeting.
public struct Transcript: Codable, Sendable, Hashable {
    /// Mean per-token ASR confidence, per source. `asr_mic` is `null` for `onsite`,
    /// which has no separate microphone channel.
    public struct Confidence: Codable, Sendable, Hashable {
        public var asrRoom: Double?
        public var asrMic: Double?

        public init(asrRoom: Double? = nil, asrMic: Double? = nil) {
            self.asrRoom = asrRoom
            self.asrMic = asrMic
        }

        enum CodingKeys: String, CodingKey {
            case asrRoom = "asr_room"
            case asrMic = "asr_mic"
        }

        /// Written by hand so that a missing source appears as an explicit `null`
        /// rather than a missing key, which is what the specification shows and what
        /// tells a reader that the source was absent instead of unrecorded.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(asrRoom, forKey: .asrRoom)
            try container.encode(asrMic, forKey: .asrMic)
        }
    }

    public var mode: MeetingMode
    public var utterances: [Utterance]
    public var diarization: [DiarSegment]
    public var models: ModelIdentifiers
    public var confidence: Confidence

    public init(
        mode: MeetingMode,
        utterances: [Utterance],
        diarization: [DiarSegment],
        models: ModelIdentifiers,
        confidence: Confidence
    ) {
        self.mode = mode
        self.utterances = utterances
        self.diarization = diarization
        self.models = models
        self.confidence = confidence
    }

    /// Every speaker label used, in the order they first speak.
    public var speakers: [String] {
        var seen: Set<String> = []
        return utterances.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    /// End of the last utterance, or 0 for an empty transcript.
    public var lastSpeechEnd: TimeInterval { utterances.last?.end ?? 0 }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public func jsonData() throws -> Data {
        try Self.encoder().encode(self)
    }

    public static func decode(from data: Data) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: data)
    }
}

/// One token as the recognizer produced it, before speakers are attached.
///
/// This is the merger's input, mapped from `FluidAudio.TokenTiming` by the app layer:
/// the app strips the recognizer's subword markers, and `StenoCore` gets plain words.
public struct ASRToken: Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// Per-token confidence, if the recognizer reported one.
    public var confidence: Double?

    public init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    /// The instant used for every speaker decision. A token belongs to whoever was
    /// speaking in its middle, not at its edges — the edges are exactly where the
    /// recognizer's and the diarizer's disagreements pile up.
    public var midpoint: TimeInterval { start + (end - start) / 2 }
}

/// The reserved speaker labels.
public enum SpeakerLabel {
    /// The user. Only reachable in `online` mode, where the microphone is its own channel.
    public static let me = "ME"
    /// No diarization segment covered the token's midpoint.
    public static let unknown = "UNKNOWN"
    /// Prefix for diarized speakers, numbered by first appearance: `S1`, `S2`, …
    public static let diarizedPrefix = "S"

    public static func diarized(_ index: Int) -> String { "\(diarizedPrefix)\(index)" }

    /// Whether a label is one of the reserved names rather than a diarized speaker.
    public static func isReserved(_ label: String) -> Bool {
        label == me || label == unknown
    }
}
