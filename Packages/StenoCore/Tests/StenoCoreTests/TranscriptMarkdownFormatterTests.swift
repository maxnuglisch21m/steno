import Foundation
import Testing

@testable import StenoCore

@Suite("TranscriptMarkdownFormatter")
struct TranscriptMarkdownFormatterTests {
    static let berlin = TimeZone(secondsFromGMT: 7200)!
    /// 2026-09-09T14:30:12+02:00
    static let started = Date(timeIntervalSince1970: 1_788_957_012)

    static let models = ModelIdentifiers(
        asr: "parakeet-tdt-0.6b-v3",
        diarizer: "pyannote-community-1"
    )

    static func transcript(
        mode: MeetingMode = .onsite,
        utterances: [Utterance],
        confidence: Transcript.Confidence = Transcript.Confidence(asrRoom: 0.89)
    ) -> Transcript {
        Transcript(
            mode: mode,
            utterances: utterances,
            diarization: [],
            models: models,
            confidence: confidence
        )
    }

    static func utterance(_ speaker: String, _ start: TimeInterval, _ text: String) -> Utterance {
        Utterance(
            speaker: speaker,
            start: start,
            end: start + 2,
            text: text,
            tokens: [Token(t: start, w: text)]
        )
    }

    // MARK: - Lines

    @Test("renders the lines from the specification")
    func specificationLines() {
        let formatter = TranscriptMarkdownFormatter(timeZone: Self.berlin)
        #expect(
            formatter.line(for: Self.utterance("S1", 12.30, "Also der Centerplan ist durch."))
                == "[00:00:12] S1: Also der Centerplan ist durch."
        )
        #expect(
            formatter.line(for: Self.utterance("S2", 15.02, "Dann können wir den Druck freigeben."))
                == "[00:00:15] S2: Dann können wir den Druck freigeben."
        )
    }

    @Test(
        "formats the clock",
        arguments: [
            (0.0, "00:00:00"),
            (0.9, "00:00:00"),
            (12.30, "00:00:12"),
            (59.99, "00:00:59"),
            (60.0, "00:01:00"),
            (3599.0, "00:59:59"),
            (3600.0, "01:00:00"),
            (2552.0, "00:42:32"),
            // Hours count upwards rather than wrapping at 24.
            (86_400.0, "24:00:00"),
            (90_061.0, "25:01:01"),
            // Nonsense produces a clock rather than a crash.
            (-5.0, "00:00:00")
        ]
    )
    func clock(seconds: TimeInterval, expected: String) {
        #expect(TranscriptMarkdownFormatter.clock(seconds) == expected)
    }

    @Test("a non-finite time does not produce garbage")
    func nonFiniteClock() {
        #expect(TranscriptMarkdownFormatter.clock(.nan) == "00:00:00")
        #expect(TranscriptMarkdownFormatter.clock(.infinity) == "00:00:00")
    }

    @Test("ME lines read like any other speaker's")
    func meLine() {
        let formatter = TranscriptMarkdownFormatter(timeZone: Self.berlin)
        #expect(
            formatter.line(for: Self.utterance("ME", 185, "Warte mal."))
                == "[00:03:05] ME: Warte mal."
        )
    }

    // MARK: - Whole document

    @Test("writes the header block and then the transcript")
    func wholeDocument() {
        let formatter = TranscriptMarkdownFormatter(timeZone: Self.berlin)
        let markdown = formatter.markdown(
            for: Self.transcript(
                utterances: [
                    Self.utterance("S1", 12.30, "Also der Centerplan ist durch."),
                    Self.utterance("S2", 15.02, "Dann können wir den Druck freigeben.")
                ]
            ),
            started: Self.started,
            duration: 2552
        )

        #expect(
            markdown == """
            # Steno transcript

            - Mode: onsite
            - Started: 2026-09-09T14:30:12+02:00
            - Duration: 00:42:32
            - Speakers: S1, S2
            - ASR model: parakeet-tdt-0.6b-v3
            - Diarization model: pyannote-community-1
            - Confidence (room): 0.89

            [00:00:12] S1: Also der Centerplan ist durch.
            [00:00:15] S2: Dann können wir den Druck freigeben.

            """
        )
    }

    @Test("an online transcript reports both confidences")
    func onlineHeader() {
        let markdown = TranscriptMarkdownFormatter(timeZone: Self.berlin).markdown(
            for: Self.transcript(
                mode: .online,
                utterances: [Self.utterance("ME", 3, "Warte mal.")],
                confidence: Transcript.Confidence(asrRoom: 0.86, asrMic: 0.96)
            ),
            started: Self.started,
            duration: 600
        )
        #expect(markdown.contains("- Mode: online"))
        #expect(markdown.contains("- Confidence (room): 0.86"))
        #expect(markdown.contains("- Confidence (mic): 0.96"))
        #expect(markdown.contains("- Speakers: ME"))
    }

    @Test("omits a confidence it does not have")
    func omitsMissingConfidence() {
        let markdown = TranscriptMarkdownFormatter(timeZone: Self.berlin).markdown(
            for: Self.transcript(
                utterances: [Self.utterance("S1", 1, "Hallo")],
                confidence: Transcript.Confidence()
            )
        )
        #expect(!markdown.contains("Confidence"))
    }

    @Test("omits the start when it is not known")
    func omitsMissingStart() {
        let markdown = TranscriptMarkdownFormatter(timeZone: Self.berlin).markdown(
            for: Self.transcript(utterances: [Self.utterance("S1", 1, "Hallo")])
        )
        #expect(!markdown.contains("- Started:"))
        #expect(markdown.contains("- Mode: onsite"))
    }

    @Test("falls back to the last utterance for the duration")
    func durationFallback() {
        let markdown = TranscriptMarkdownFormatter(timeZone: Self.berlin).markdown(
            for: Self.transcript(utterances: [Self.utterance("S1", 100, "Ende")])
        )
        // The utterance runs 100…102.
        #expect(markdown.contains("- Duration: 00:01:42"))
    }

    @Test("says so when nothing was recognized instead of writing an empty file")
    func emptyTranscript() {
        let markdown = TranscriptMarkdownFormatter(timeZone: Self.berlin).markdown(
            for: Self.transcript(utterances: [], confidence: Transcript.Confidence()),
            started: Self.started,
            duration: 60
        )
        #expect(markdown.contains("_No speech was recognized._"))
        #expect(markdown.contains("- Speakers: —"))
        #expect(markdown.contains("- Duration: 00:01:00"))
    }

    @Test("the speaker list can be left out")
    func withoutSpeakerList() {
        let markdown = TranscriptMarkdownFormatter(timeZone: Self.berlin, includesSpeakerList: false)
            .markdown(for: Self.transcript(utterances: [Self.utterance("S1", 1, "Hallo")]))
        #expect(!markdown.contains("- Speakers:"))
    }

    @Test("renders the start in the given time zone")
    func timeZoneMatters() {
        let markdown = TranscriptMarkdownFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
            .markdown(
                for: Self.transcript(utterances: []),
                started: Self.started
            )
        #expect(markdown.contains("- Started: 2026-09-09T12:30:12Z"))
    }

    @Test("ends with a single newline")
    func trailingNewline() {
        let markdown = TranscriptMarkdownFormatter().markdown(
            for: Self.transcript(utterances: [Self.utterance("S1", 1, "Hallo")])
        )
        #expect(markdown.hasSuffix("Hallo\n"))
        #expect(!markdown.hasSuffix("\n\n"))
    }

    @Test("the whole meeting is covered without a gap of its own making")
    func coversTheTimeline() {
        // Acceptance criterion §11.9 reads the produced file; this checks the file
        // reflects every utterance it was given, in order.
        let utterances = (0..<20).map { Self.utterance("S\($0 % 3 + 1)", TimeInterval($0) * 30, "Satz \($0)") }
        let markdown = TranscriptMarkdownFormatter(timeZone: Self.berlin)
            .markdown(for: Self.transcript(utterances: utterances), duration: 600)
        let lines = markdown.split(separator: "\n").filter { $0.hasPrefix("[") }
        #expect(lines.count == 20)
        #expect(lines.first == "[00:00:00] S1: Satz 0")
        #expect(lines.last == "[00:09:30] S2: Satz 19")
    }

    @Test("keeps German text intact")
    func germanText() {
        let markdown = TranscriptMarkdownFormatter(timeZone: Self.berlin).markdown(
            for: Self.transcript(
                utterances: [Self.utterance("S1", 0, "Die Ratecard für Österreich hängt an der Größe.")]
            )
        )
        #expect(markdown.contains("Ratecard für Österreich hängt an der Größe."))
    }
}
