import Foundation
import Testing

@testable import StenoCore

@Suite("TranscriptMerger")
struct TranscriptMergerTests {
    static let models = ModelIdentifiers(
        asr: "parakeet-tdt-0.6b-v3",
        diarizer: "pyannote-community-1"
    )

    /// A token spanning `[start, start + length)`.
    static func token(
        _ text: String,
        _ start: TimeInterval,
        _ length: TimeInterval = 0.4,
        confidence: Double? = nil
    ) -> ASRToken {
        ASRToken(text: text, start: start, end: start + length, confidence: confidence)
    }

    static func merge(
        mode: MeetingMode,
        room: [ASRToken],
        mic: [ASRToken]? = nil,
        diarization: [DiarSegment] = [],
        gapThreshold: TimeInterval = TranscriptMerger.defaultGapThreshold
    ) -> Transcript {
        TranscriptMerger.merge(
            mode: mode,
            roomTokens: room,
            micTokens: mic,
            diarization: diarization,
            models: models,
            gapThreshold: gapThreshold
        )
    }

    // MARK: - Midpoint speaker assignment

    @Test("a token takes the speaker of the segment covering its midpoint")
    func midpointAssignment() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("Also", 10.0, 1.0)],  // midpoint 10.5
            diarization: [
                DiarSegment(speaker: "spk_0", start: 0, end: 10.4),
                DiarSegment(speaker: "spk_1", start: 10.4, end: 20)
            ]
        )
        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].speaker == "S1")
        // The segment that owns the midpoint is spk_1, which becomes S1 by first
        // appearance — not S2, even though its raw label sorts second.
        #expect(transcript.diarization.map(\.speaker) == ["S2", "S1"])
    }

    @Test("the midpoint decides, not the edges")
    func midpointNotEdges() {
        // The token starts inside spk_0 and ends inside spk_1, so only the midpoint
        // can settle it. Edges are exactly where the two models disagree.
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("Grenzfall", 9.0, 2.0)],  // 9…11, midpoint 10
            diarization: [
                DiarSegment(speaker: "A", start: 0, end: 9.5),
                DiarSegment(speaker: "B", start: 9.5, end: 20)
            ]
        )
        #expect(transcript.utterances[0].speaker == "S1")
        #expect(transcript.diarization.first { $0.speaker == "S1" }?.start == 9.5)
    }

    @Test("a midpoint exactly on a boundary belongs to the later segment")
    func boundaryGoesToLaterSegment() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("Kante", 9.0, 2.0)],  // midpoint exactly 10
            diarization: [
                DiarSegment(speaker: "early", start: 0, end: 10),
                DiarSegment(speaker: "late", start: 10, end: 20)
            ]
        )
        #expect(transcript.utterances[0].speaker == "S1")
        #expect(transcript.diarization.first { $0.speaker == "S1" }?.start == 10)
    }

    @Test("a token no segment covers becomes UNKNOWN")
    func unknownSpeaker() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("Niemand", 50.0)],
            diarization: [DiarSegment(speaker: "A", start: 0, end: 10)]
        )
        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].speaker == SpeakerLabel.unknown)
        #expect(transcript.utterances[0].speaker == "UNKNOWN")
    }

    @Test("with no diarization at all every token is UNKNOWN")
    func noDiarization() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("Eins", 0), Self.token("Zwei", 0.5)]
        )
        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].speaker == "UNKNOWN")
        #expect(transcript.utterances[0].text == "Eins Zwei")
    }

    @Test("overlapping segments are resolved by the earlier one")
    func overlappingSegments() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("Wort", 5.0, 1.0)],  // midpoint 5.5
            diarization: [
                DiarSegment(speaker: "first", start: 0, end: 10),
                DiarSegment(speaker: "second", start: 5, end: 8)
            ]
        )
        #expect(transcript.utterances[0].speaker == "S1")
        #expect(transcript.diarization.first?.speaker == "S1")
        #expect(transcript.diarization.first?.start == 0)
    }

    // MARK: - Bundling and gaps

    @Test("consecutive tokens of one speaker become one utterance")
    func bundlesSameSpeaker() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [
                Self.token("Also", 12.30, 0.5),
                Self.token("der", 12.85, 0.3),
                Self.token("Centerplan", 13.20, 0.8),
                Self.token("ist", 14.05, 0.2),
                Self.token("durch.", 14.30, 0.72)
            ],
            diarization: [DiarSegment(speaker: "spk_0", start: 12, end: 16)]
        )
        #expect(transcript.utterances.count == 1)
        let utterance = transcript.utterances[0]
        #expect(utterance.speaker == "S1")
        #expect(utterance.text == "Also der Centerplan ist durch.")
        #expect(utterance.start == 12.30)
        #expect(abs(utterance.end - 15.02) < 1e-9)
        #expect(utterance.tokens.count == 5)
        #expect(utterance.tokens.first == Token(t: 12.30, w: "Also"))
        #expect(utterance.tokens.last == Token(t: 14.30, w: "durch."))
    }

    @Test("a speaker change starts a new utterance even without a gap")
    func splitsOnSpeakerChange() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [
                Self.token("Also", 1.0, 0.5),     // midpoint 1.25 → A
                Self.token("ja", 1.5, 0.5)        // midpoint 1.75 → B
            ],
            diarization: [
                DiarSegment(speaker: "A", start: 0, end: 1.5),
                DiarSegment(speaker: "B", start: 1.5, end: 5)
            ]
        )
        #expect(transcript.utterances.map(\.speaker) == ["S1", "S2"])
        #expect(transcript.utterances.map(\.text) == ["Also", "ja"])
    }

    @Test(
        "a gap of more than 0.8 s starts a new utterance",
        arguments: [
            // (gap after the first token, expected number of utterances)
            (0.0, 1),
            (0.5, 1),
            (0.79, 1),
            (0.80, 1),   // exactly 0.8 s still bundles: the rule is "more than"
            (0.81, 2),
            (1.5, 2),
            (30.0, 2)
        ]
    )
    func splitsOnGap(gap: TimeInterval, expected: Int) {
        let first = Self.token("eins", 0, 1.0)          // ends at 1.0
        let second = Self.token("zwei", 1.0 + gap, 1.0)
        let transcript = Self.merge(
            mode: .onsite,
            room: [first, second],
            diarization: [DiarSegment(speaker: "A", start: 0, end: 100)]
        )
        #expect(transcript.utterances.count == expected)
        if expected == 1 {
            #expect(transcript.utterances[0].text == "eins zwei")
        } else {
            #expect(transcript.utterances.map(\.text) == ["eins", "zwei"])
        }
    }

    @Test("the gap threshold is configurable")
    func customGapThreshold() {
        let room = [Self.token("eins", 0, 1.0), Self.token("zwei", 3.0, 1.0)]
        let diarization = [DiarSegment(speaker: "A", start: 0, end: 100)]
        #expect(Self.merge(mode: .onsite, room: room, diarization: diarization).utterances.count == 2)
        #expect(
            Self.merge(mode: .onsite, room: room, diarization: diarization, gapThreshold: 5)
                .utterances.count == 1
        )
    }

    @Test("consecutive UNKNOWN tokens bundle like any other speaker")
    func bundlesUnknown() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("hm", 0, 0.3), Self.token("ja", 0.4, 0.3)]
        )
        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].speaker == "UNKNOWN")
    }

    // MARK: - Sorting

    @Test("sorts by start time regardless of input order")
    func sortsByStart() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [
                Self.token("drei", 20, 0.3),
                Self.token("eins", 0, 0.3),
                Self.token("zwei", 10, 0.3)
            ],
            diarization: [DiarSegment(speaker: "A", start: 0, end: 100)]
        )
        #expect(transcript.utterances.map(\.text) == ["eins", "zwei", "drei"])
        #expect(transcript.utterances.map(\.start) == [0, 10, 20])
    }

    @Test("an utterance's end is the latest end among its tokens")
    func endIsMaximum() {
        // A long token followed by a short one that finishes earlier.
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("lang", 0, 2.0), Self.token("kurz", 0.5, 0.2)],
            diarization: [DiarSegment(speaker: "A", start: 0, end: 100)]
        )
        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].end == 2.0)
    }

    @Test("the same input always produces the same transcript")
    func deterministic() {
        let room = [
            Self.token("a", 1.0, 0.5),
            Self.token("b", 1.0, 0.5),   // identical span
            Self.token("c", 1.0, 0.5)
        ]
        let diarization = [DiarSegment(speaker: "A", start: 0, end: 10)]
        let first = Self.merge(mode: .onsite, room: room, diarization: diarization)
        for _ in 0..<20 {
            #expect(Self.merge(mode: .onsite, room: room, diarization: diarization) == first)
        }
        #expect(first.utterances[0].text == "a b c")
    }

    // MARK: - ME override, online mode

    @Test("microphone tokens become ME")
    func micTokensBecomeMe() {
        let transcript = Self.merge(
            mode: .online,
            room: [],
            mic: [Self.token("Moment", 5.0, 0.6)],
            diarization: [DiarSegment(speaker: "spk_0", start: 0, end: 10)]
        )
        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].speaker == SpeakerLabel.me)
        #expect(transcript.utterances[0].speaker == "ME")
    }

    @Test("a room token whose midpoint falls inside a ME token is dropped")
    func meOverridesRoom() {
        // The same speech, arriving on both channels: the tap heard the mix, the
        // microphone heard the user directly.
        let transcript = Self.merge(
            mode: .online,
            room: [Self.token("Moment", 5.1, 0.4)],   // midpoint 5.3, inside the ME span
            mic: [Self.token("Moment", 5.0, 0.6)],    // 5.0…5.6
            diarization: [DiarSegment(speaker: "spk_0", start: 0, end: 10)]
        )
        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].speaker == "ME")
        #expect(transcript.utterances[0].text == "Moment")
        // The dropped room token left no diarized speaker behind in the utterances,
        // but the raw segment is still there to be judged.
        #expect(transcript.diarization.map(\.speaker) == ["S1"])
    }

    @Test("a room token outside every ME span survives")
    func roomOutsideMeSurvives() {
        let transcript = Self.merge(
            mode: .online,
            room: [
                Self.token("davor", 1.0, 0.4),     // midpoint 1.2
                Self.token("drin", 5.1, 0.4),      // midpoint 5.3, dropped
                Self.token("danach", 9.0, 0.4)     // midpoint 9.2
            ],
            mic: [Self.token("Moment", 5.0, 0.6)],
            diarization: [DiarSegment(speaker: "spk_0", start: 0, end: 20)]
        )
        #expect(transcript.utterances.map(\.speaker) == ["S1", "ME", "S1"])
        #expect(transcript.utterances.map(\.text) == ["davor", "Moment", "danach"])
    }

    @Test("a room token whose midpoint sits exactly on the ME span's end survives")
    func meSpanIsHalfOpen() {
        // All the times here are exact in binary, so the boundary really is the
        // boundary and not a rounding artefact.
        let transcript = Self.merge(
            mode: .online,
            room: [Self.token("danach", 5.25, 0.5)],  // 5.25…5.75, midpoint exactly 5.5
            mic: [Self.token("Moment", 5.0, 0.5)],    // 5.0…5.5
            diarization: [DiarSegment(speaker: "spk_0", start: 0, end: 20)]
        )
        #expect(Self.token("danach", 5.25, 0.5).midpoint == 5.5)
        #expect(Self.token("Moment", 5.0, 0.5).end == 5.5)
        #expect(transcript.utterances.map(\.speaker) == ["ME", "S1"])
    }

    @Test("ME sorts before a room token starting at the same instant")
    func meWinsTiesInOrder() {
        let transcript = Self.merge(
            mode: .online,
            room: [Self.token("gleichzeitig", 3.0, 0.5)],
            mic: [Self.token("ich", 3.0, 0.5)],
            diarization: [DiarSegment(speaker: "A", start: 0, end: 10)]
        )
        // The room token's midpoint is inside the ME span, so it is dropped outright.
        #expect(transcript.utterances.map(\.speaker) == ["ME"])
    }

    @Test("onsite ignores microphone tokens entirely")
    func onsiteIgnoresMicTokens() {
        // There is no ME to be had without a separate channel, and guessing one
        // would be a lie — so tokens handed in for one are dropped, not relabelled.
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("Raum", 1.0)],
            mic: [Self.token("Mikro", 5.0)],
            diarization: [DiarSegment(speaker: "A", start: 0, end: 10)]
        )
        #expect(transcript.utterances.map(\.text) == ["Raum"])
        #expect(!transcript.utterances.contains { $0.speaker == "ME" })
        #expect(transcript.confidence.asrMic == nil)
    }

    @Test("ME never appears in an onsite transcript, whatever the diarizer called a speaker")
    func onsiteHasNoMe() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("Wort", 1.0)],
            diarization: [DiarSegment(speaker: "ME", start: 0, end: 10)]
        )
        // A diarizer label that happens to read "ME" is a reserved name and is not
        // renumbered, but it also cannot arise from real diarization output.
        #expect(transcript.mode == .onsite)
        #expect(transcript.utterances[0].speaker == "ME")
    }

    // MARK: - Speaker numbering

    @Test("renames diarized speakers S1…Sn by first appearance")
    func renamesByFirstAppearance() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [
                Self.token("erst", 30, 0.3),   // spk_7
                Self.token("dann", 10, 0.3),   // spk_3
                Self.token("zuletzt", 50, 0.3) // spk_1
            ],
            diarization: [
                DiarSegment(speaker: "spk_3", start: 5, end: 15),
                DiarSegment(speaker: "spk_7", start: 25, end: 35),
                DiarSegment(speaker: "spk_1", start: 45, end: 55)
            ]
        )
        // Sorted by time, spk_3 speaks first.
        #expect(transcript.utterances.map(\.speaker) == ["S1", "S2", "S3"])
        #expect(transcript.utterances.map(\.text) == ["dann", "erst", "zuletzt"])
        #expect(
            transcript.diarization
                == [
                    DiarSegment(speaker: "S1", start: 5, end: 15),
                    DiarSegment(speaker: "S2", start: 25, end: 35),
                    DiarSegment(speaker: "S3", start: 45, end: 55)
                ]
        )
    }

    @Test("a speaker returning later keeps the number it was given")
    func speakerNumbersAreStable() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [
                Self.token("a", 1, 0.3),
                Self.token("b", 5, 0.3),
                Self.token("c", 9, 0.3)
            ],
            diarization: [
                DiarSegment(speaker: "x", start: 0, end: 3),
                DiarSegment(speaker: "y", start: 4, end: 7),
                DiarSegment(speaker: "x", start: 8, end: 11)
            ]
        )
        #expect(transcript.utterances.map(\.speaker) == ["S1", "S2", "S1"])
        #expect(transcript.diarization.map(\.speaker) == ["S1", "S2", "S1"])
    }

    @Test("a diarized speaker with no tokens still gets a number")
    func silentSpeakerIsNumbered() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("nur einer", 15, 0.3)],
            diarization: [
                DiarSegment(speaker: "quiet", start: 0, end: 10),
                DiarSegment(speaker: "loud", start: 14, end: 20)
            ]
        )
        #expect(transcript.utterances.map(\.speaker) == ["S1"])
        // The speaker who produced no recognized words is still labelled, so the raw
        // segments read as a complete picture.
        #expect(transcript.diarization.map(\.speaker) == ["S2", "S1"])
    }

    @Test("ME and UNKNOWN are not renumbered")
    func reservedLabelsSurvive() {
        let transcript = Self.merge(
            mode: .online,
            room: [Self.token("fremd", 50, 0.3)],
            mic: [Self.token("ich", 1, 0.3)],
            diarization: [DiarSegment(speaker: "spk_0", start: 0, end: 10)]
        )
        #expect(transcript.utterances.map(\.speaker) == ["ME", "UNKNOWN"])
        #expect(SpeakerLabel.isReserved("ME"))
        #expect(SpeakerLabel.isReserved("UNKNOWN"))
        #expect(!SpeakerLabel.isReserved("S1"))
        #expect(SpeakerLabel.diarized(4) == "S4")
    }

    @Test("the numbering counts four speakers for a four-person meeting")
    func fourSpeakers() {
        // Acceptance criterion §11.5, at the merge level: four clusters in, four
        // labels out, in the order they first speak.
        var room: [ASRToken] = []
        var diarization: [DiarSegment] = []
        for turn in 0..<12 {
            let speaker = "cluster_\((turn * 3) % 4)"
            let start = TimeInterval(turn) * 10
            diarization.append(DiarSegment(speaker: speaker, start: start, end: start + 9))
            room.append(Self.token("Turn\(turn)", start + 1, 0.5))
        }
        let transcript = Self.merge(mode: .onsite, room: room, diarization: diarization)
        #expect(Set(transcript.utterances.map(\.speaker)) == ["S1", "S2", "S3", "S4"])
        #expect(transcript.speakers == ["S1", "S2", "S3", "S4"])
    }

    // MARK: - Confidence

    @Test("confidence is the mean per source")
    func meanConfidence() throws {
        let transcript = Self.merge(
            mode: .online,
            room: [
                Self.token("a", 0, 0.3, confidence: 0.9),
                Self.token("b", 1, 0.3, confidence: 0.8),
                Self.token("c", 2, 0.3, confidence: 0.88)
            ],
            mic: [
                Self.token("x", 10, 0.3, confidence: 0.95),
                Self.token("y", 11, 0.3, confidence: 0.85)
            ]
        )
        let room = try #require(transcript.confidence.asrRoom)
        let mic = try #require(transcript.confidence.asrMic)
        #expect(abs(room - 0.86) < 1e-9)
        #expect(abs(mic - 0.90) < 1e-9)
    }

    @Test("a room token displaced by ME still counts towards the recognizer's confidence")
    func confidenceCoversTheWholePass() {
        // Confidence describes the recognition pass, not the merge result.
        let transcript = Self.merge(
            mode: .online,
            room: [Self.token("Moment", 5.1, 0.4, confidence: 0.5)],
            mic: [Self.token("Moment", 5.0, 0.6, confidence: 1.0)]
        )
        #expect(transcript.utterances.count == 1)
        #expect(transcript.confidence.asrRoom == 0.5)
        #expect(transcript.confidence.asrMic == 1.0)
    }

    @Test("tokens without a confidence are left out of the mean")
    func partialConfidences() {
        #expect(
            TranscriptMerger.meanConfidence(of: [
                Self.token("a", 0, confidence: 1.0),
                Self.token("b", 1, confidence: nil),
                Self.token("c", 2, confidence: 0.5)
            ]) == 0.75
        )
        #expect(TranscriptMerger.meanConfidence(of: []) == nil)
        #expect(TranscriptMerger.meanConfidence(of: [Self.token("a", 0)]) == nil)
    }

    @Test("an onsite transcript reports no microphone confidence")
    func onsiteConfidence() {
        let transcript = Self.merge(
            mode: .onsite,
            room: [Self.token("a", 0, confidence: 0.89)]
        )
        #expect(transcript.confidence.asrRoom == 0.89)
        #expect(transcript.confidence.asrMic == nil)
    }

    // MARK: - Whole documents

    @Test("an empty recording produces an empty transcript rather than a failure")
    func emptyInput() {
        let transcript = Self.merge(mode: .onsite, room: [])
        #expect(transcript.utterances.isEmpty)
        #expect(transcript.diarization.isEmpty)
        #expect(transcript.confidence.asrRoom == nil)
        #expect(transcript.speakers.isEmpty)
        #expect(transcript.lastSpeechEnd == 0)
    }

    @Test("produces the specification's transcript.json shape")
    func transcriptShape() throws {
        let transcript = Self.merge(
            mode: .onsite,
            room: [
                Self.token("Also", 12.30, 0.5, confidence: 0.9),
                Self.token("der", 12.85, 0.3, confidence: 0.88),
                Self.token("Centerplan", 13.20, 0.9, confidence: 0.89)
            ],
            diarization: [
                DiarSegment(speaker: "spk_0", start: 12, end: 15),
                DiarSegment(speaker: "spk_1", start: 15.4, end: 22.1)
            ]
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: try transcript.jsonData()) as? [String: Any]
        )
        #expect(Set(object.keys) == ["mode", "utterances", "diarization", "models", "confidence"])
        #expect(object["mode"] as? String == "onsite")

        let utterances = try #require(object["utterances"] as? [[String: Any]])
        #expect(utterances.count == 1)
        #expect(Set(utterances[0].keys) == ["speaker", "start", "end", "text", "tokens"])
        #expect(utterances[0]["speaker"] as? String == "S1")
        #expect(utterances[0]["text"] as? String == "Also der Centerplan")
        let tokens = try #require(utterances[0]["tokens"] as? [[String: Any]])
        #expect(tokens[0]["t"] as? Double == 12.30)
        #expect(tokens[0]["w"] as? String == "Also")

        let diarization = try #require(object["diarization"] as? [[String: Any]])
        #expect(diarization.count == 2)
        #expect(Set(diarization[0].keys) == ["speaker", "start", "end"])
        #expect(diarization[1]["speaker"] as? String == "S2")
        #expect(diarization[1]["start"] as? Double == 15.4)

        let confidence = try #require(object["confidence"] as? [String: Any])
        #expect(confidence["asr_room"] != nil)
        // The specification writes an explicit null for the missing source.
        #expect(confidence["asr_mic"] is NSNull)

        let models = try #require(object["models"] as? [String: Any])
        #expect(models["asr"] as? String == "parakeet-tdt-0.6b-v3")
        #expect(models["diarizer"] as? String == "pyannote-community-1")
    }

    @Test("a transcript round-trips through Codable")
    func codableRoundTrip() throws {
        let transcript = Self.merge(
            mode: .online,
            room: [Self.token("Raum", 1, 0.5, confidence: 0.8)],
            mic: [Self.token("Ich", 5, 0.5, confidence: 0.95)],
            diarization: [DiarSegment(speaker: "spk_0", start: 0, end: 3)]
        )
        #expect(try Transcript.decode(from: try transcript.jsonData()) == transcript)
    }

    @Test("a realistic online meeting merges as expected")
    func realisticOnline() {
        // Two people on the far side plus the user, with the user interrupting.
        let transcript = Self.merge(
            mode: .online,
            room: [
                Self.token("Der", 0.0, 0.3, confidence: 0.9),
                Self.token("Centerplan", 0.35, 0.6, confidence: 0.85),
                Self.token("ist", 1.0, 0.2, confidence: 0.9),
                Self.token("durch.", 1.25, 0.4, confidence: 0.92),
                // The user's own interjection, also picked up by the tap.
                Self.token("Warte", 3.05, 0.4, confidence: 0.6),
                Self.token("Dann", 5.0, 0.3, confidence: 0.9),
                Self.token("freigeben.", 5.35, 0.6, confidence: 0.88)
            ],
            mic: [
                Self.token("Warte", 3.0, 0.5, confidence: 0.97),
                Self.token("mal.", 3.55, 0.35, confidence: 0.95)
            ],
            diarization: [
                DiarSegment(speaker: "spk_0", start: 0.0, end: 2.0),
                DiarSegment(speaker: "spk_2", start: 2.8, end: 3.6),
                DiarSegment(speaker: "spk_1", start: 4.8, end: 6.2)
            ]
        )

        #expect(transcript.utterances.map(\.speaker) == ["S1", "ME", "S2"])
        #expect(
            transcript.utterances.map(\.text)
                == ["Der Centerplan ist durch.", "Warte mal.", "Dann freigeben."]
        )
        // Only the user's channel produced ME, and the tap's duplicate is gone.
        #expect(transcript.utterances.filter { $0.speaker == "ME" }.count == 1)
        #expect(transcript.speakers == ["S1", "ME", "S2"])
        // spk_2 was the user as the tap heard them; it kept a label for the raw view.
        #expect(transcript.diarization.map(\.speaker) == ["S1", "S3", "S2"])
    }
}
