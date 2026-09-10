import Foundation

/// Renders `transcript.md`: a header block, a blank line, then one line per utterance.
///
/// ```
/// # Steno transcript
///
/// - Mode: onsite
/// - Started: 2026-09-09T14:30:12+02:00
/// - Duration: 00:42:32
/// - Speakers: S1, S2, S3
/// - ASR model: parakeet-tdt-0.6b-v3
/// - Diarization model: pyannote-community-1
/// - Confidence (room): 0.89
///
/// [00:00:12] S1: Also der Centerplan ist durch.
/// [00:00:15] S2: Dann können wir den Druck freigeben.
/// ```
///
/// The header labels are English and fixed. `transcript.md` is part of the data
/// contract a downstream tool reads, not interface text, so it stays out of the
/// string catalog and does not change with the interface language — only the
/// transcribed speech itself is in whatever language the meeting was held in.
public struct TranscriptMarkdownFormatter: Sendable {
    public var timeZone: TimeZone
    /// Included so a reader knows which labels were guessed rather than measured.
    public var includesSpeakerList: Bool

    public init(timeZone: TimeZone = .current, includesSpeakerList: Bool = true) {
        self.timeZone = timeZone
        self.includesSpeakerList = includesSpeakerList
    }

    /// - Parameters:
    ///   - transcript: the merged transcript.
    ///   - started: when the recording began, for the header. Omitted from the header
    ///     when `nil`.
    ///   - duration: the recording's length. Falls back to the end of the last
    ///     utterance when `nil`.
    public func markdown(
        for transcript: Transcript,
        started: Date? = nil,
        duration: TimeInterval? = nil
    ) -> String {
        var lines: [String] = ["# Steno transcript", ""]

        lines.append("- Mode: \(transcript.mode.rawValue)")
        if let started {
            lines.append("- Started: \(ISO8601Timestamp.string(from: started, timeZone: timeZone))")
        }
        let effectiveDuration = duration ?? transcript.lastSpeechEnd
        lines.append("- Duration: \(Self.clock(effectiveDuration))")
        if includesSpeakerList {
            let speakers = transcript.speakers
            lines.append("- Speakers: \(speakers.isEmpty ? "—" : speakers.joined(separator: ", "))")
        }
        lines.append("- ASR model: \(transcript.models.asr)")
        lines.append("- Diarization model: \(transcript.models.diarizer)")
        if let room = transcript.confidence.asrRoom {
            lines.append("- Confidence (room): \(Self.confidence(room))")
        }
        if let mic = transcript.confidence.asrMic {
            lines.append("- Confidence (mic): \(Self.confidence(mic))")
        }

        lines.append("")
        if transcript.utterances.isEmpty {
            lines.append("_No speech was recognized._")
        } else {
            for utterance in transcript.utterances {
                lines.append(line(for: utterance))
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// One transcript line: `[00:00:12] S1: Also der Centerplan ist durch.`
    public func line(for utterance: Utterance) -> String {
        "[\(Self.clock(utterance.start))] \(utterance.speaker): \(utterance.text)"
    }

    /// `HH:MM:SS`, counting hours upwards rather than wrapping at 24.
    ///
    /// `ElapsedClock` does the formatting, because the screenshot file names carry the
    /// same clock without its colons and the two must agree to the second.
    public static func clock(_ seconds: TimeInterval) -> String {
        ElapsedClock.string(seconds)
    }

    private static func confidence(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
