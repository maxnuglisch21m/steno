import Foundation
import Testing

@testable import StenoCore

/// SentencePiece pieces in, words out.
///
/// The fixtures below are shaped like what Parakeet actually emits: a leading `▁`
/// marks a word start, everything else continues the word, and German compounds come
/// apart into two or three pieces.
@Suite("WordAssembler")
struct WordAssemblerTests {
    private func piece(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ confidence: Double? = nil
    ) -> SubwordPiece {
        SubwordPiece(text: text, start: start, end: end, confidence: confidence)
    }

    @Test("sub-word pieces join into one word with the span of all of them")
    func joinsSubwords() {
        let words = WordAssembler.words(from: [
            piece("\u{2581}Center", 12.30, 12.62),
            piece("plan", 12.62, 12.88)
        ])

        #expect(words.count == 1)
        #expect(words[0].text == "Centerplan")
        #expect(words[0].start == 12.30)
        #expect(words[0].end == 12.88)
    }

    @Test("a boundary marker starts a new word")
    func boundaryStartsWord() {
        let words = WordAssembler.words(from: [
            piece("\u{2581}Also", 0.10, 0.40),
            piece("\u{2581}der", 0.42, 0.55),
            piece("\u{2581}Rate", 0.60, 0.90),
            piece("card", 0.90, 1.10)
        ])

        #expect(words.map(\.text) == ["Also", "der", "Ratecard"])
        #expect(words.map(\.start) == [0.10, 0.42, 0.60])
        #expect(words.map(\.end) == [0.40, 0.55, 1.10])
    }

    @Test("a leading space marks a boundary just as ▁ does")
    func spaceIsABoundaryToo() {
        let words = WordAssembler.words(from: [
            piece(" Gut", 0, 0.3),
            piece(",", 0.3, 0.32),
            piece(" dann", 0.4, 0.6)
        ])

        #expect(words.map(\.text) == ["Gut,", "dann"])
    }

    @Test("the very first piece starts a word even without a marker")
    func firstPieceStartsAWord() {
        let words = WordAssembler.words(from: [
            piece("Frei", 1.0, 1.2),
            piece("gabe", 1.2, 1.4)
        ])

        #expect(words.map(\.text) == ["Freigabe"])
        #expect(words[0].start == 1.0)
        #expect(words[0].end == 1.4)
    }

    @Test("control pieces and empty pieces are dropped")
    func dropsControlPieces() {
        let words = WordAssembler.words(from: [
            piece("<blank>", 0, 0),
            piece("\u{2581}Ja", 0.1, 0.3),
            piece("<pad>", 0.3, 0.3),
            piece("", 0.3, 0.3),
            piece("\u{2581}klar", 0.4, 0.7),
            piece("<unk>", 0.7, 0.7)
        ])

        #expect(words.map(\.text) == ["Ja", "klar"])
    }

    @Test("a bare marker still separates two pieces")
    func bareMarkerSeparates() {
        let words = WordAssembler.words(from: [
            piece("\u{2581}", 0.0, 0.02),
            piece("Druck", 0.02, 0.30),
            piece("\u{2581}", 0.30, 0.32),
            piece("frei", 0.32, 0.50)
        ])

        #expect(words.map(\.text) == ["Druck", "frei"])
        #expect(words[0].start == 0.0)
        #expect(words[1].start == 0.30)
    }

    @Test("a trailing bare marker produces no empty word")
    func trailingMarkerIsNotAWord() {
        let words = WordAssembler.words(from: [
            piece("\u{2581}Schluss", 0.0, 0.4),
            piece("\u{2581}", 0.4, 0.42)
        ])

        #expect(words.map(\.text) == ["Schluss"])
    }

    @Test("a word's confidence is the mean of its pieces'")
    func averagesConfidence() throws {
        let words = WordAssembler.words(from: [
            piece("\u{2581}Roll", 0, 0.2, 0.90),
            piece("out", 0.2, 0.4, 0.70)
        ])

        let confidence = try #require(words.first?.confidence)
        #expect(abs(confidence - 0.80) < 1e-9)
    }

    @Test("pieces without a confidence do not drag the mean down")
    func ignoresMissingConfidence() {
        let words = WordAssembler.words(from: [
            piece("\u{2581}Roll", 0, 0.2, 0.90),
            piece("out", 0.2, 0.4, nil)
        ])

        #expect(words.first?.confidence == 0.90)
    }

    @Test("a word made only of pieces without confidence has none")
    func noConfidenceAtAll() {
        let words = WordAssembler.words(from: [piece("\u{2581}Hm", 0, 0.2)])
        #expect(words.first?.confidence == nil)
    }

    @Test("a piece whose span reaches back does not shorten the word")
    func endIsTheLatestEnd() {
        let words = WordAssembler.words(from: [
            piece("\u{2581}See", 1.0, 1.9),
            piece("naht", 1.2, 1.4)
        ])

        #expect(words[0].end == 1.9)
    }

    @Test("no pieces means no words")
    func emptyInput() {
        #expect(WordAssembler.words(from: []).isEmpty)
    }

    @Test("a marker inside a piece is text, not a boundary")
    func markerOnlyCountsAtTheFront() {
        #expect(WordAssembler.stripBoundaryMarker("a\u{2581}b") == "a\u{2581}b")
        #expect(WordAssembler.startsWord("a\u{2581}b") == false)
    }

    @Test("the assembled words feed the merger unchanged")
    func feedsTheMerger() {
        let words = WordAssembler.words(from: [
            piece("\u{2581}Also", 12.30, 12.60, 0.9),
            piece("\u{2581}der", 12.62, 12.80, 0.9),
            piece("\u{2581}Center", 12.82, 13.10, 0.8),
            piece("plan", 13.10, 13.40, 0.8)
        ])

        let transcript = TranscriptMerger.merge(
            mode: .onsite,
            roomTokens: words,
            diarization: [DiarSegment(speaker: "spk0", start: 12, end: 14)],
            models: ModelIdentifiers(asr: "parakeet-tdt-0.6b-v3", diarizer: "pyannote-community-1")
        )

        #expect(transcript.utterances.count == 1)
        #expect(transcript.utterances[0].text == "Also der Centerplan")
        #expect(transcript.utterances[0].speaker == "S1")
    }
}
