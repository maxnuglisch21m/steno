import Foundation

/// One piece as the recognizer's tokenizer produced it, before pieces are joined into
/// words.
///
/// Parakeet's vocabulary is SentencePiece: `"Centerplan"` comes out of the model as
/// `["▁Center", "plan"]`, and `"▁"` (U+2581 LOWER ONE EIGHTH BLOCK) is the marker that
/// says "a new word starts here". Feeding those pieces to `TranscriptMerger` unchanged
/// would put `Center` and `plan` into `transcript.json` as two separate tokens with
/// their own timestamps, and `transcript.md` would read "Also der Center plan ist
/// durch" — so the pieces are joined here first.
public struct SubwordPiece: Sendable, Hashable {
    /// The raw piece, marker and all.
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// Per-piece confidence, if the recognizer reported one.
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
}

/// Joins SentencePiece sub-word pieces into words with the timing of the pieces they
/// were built from.
///
/// The rules are the tokenizer's own, and they are few:
///
/// 1. A piece beginning with `▁` or with a space begins a new word; the marker is not
///    part of the word.
/// 2. Any other piece is appended to the word being built.
/// 3. A word starts when its first piece starts and ends when its last piece ends.
/// 4. A word's confidence is the mean of its pieces'. Pieces the recognizer gave no
///    confidence for do not drag the mean down; a word made only of those has none.
/// 5. The recognizer's control pieces (`<blank>`, `<pad>`, `<unk>`, `<s>`, `</s>`) are
///    dropped, and so is a piece that is nothing but whitespace.
///
/// This lives in `StenoCore` rather than next to the recognizer because it is the one
/// step between the model and the transcript that is pure arithmetic on strings and
/// timestamps — and therefore the one that can be tested without a 600 MB checkpoint.
public enum WordAssembler {
    /// U+2581 LOWER ONE EIGHTH BLOCK, SentencePiece's word-boundary marker.
    public static let wordBoundaryMarker: Character = "\u{2581}"

    /// Pieces that carry no text and never belong in a transcript.
    public static let controlPieces: Set<String> = ["<blank>", "<pad>", "<unk>", "<s>", "</s>"]

    /// Turns the recognizer's pieces into the words `TranscriptMerger` expects.
    ///
    /// The pieces are taken in the order given; they are assumed to be in decoding
    /// order, which is how every recognizer emits them.
    public static func words(from pieces: [SubwordPiece]) -> [ASRToken] {
        var words: [ASRToken] = []
        var current: [SubwordPiece] = []

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            let text = current
                .map { stripBoundaryMarker($0.text) }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let first = current.first else { return }
            words.append(
                ASRToken(
                    text: text,
                    start: first.start,
                    // The last piece need not hold the latest end: a recognizer that
                    // repairs a seam can emit a piece whose span reaches back.
                    end: current.map(\.end).max() ?? first.end,
                    confidence: meanConfidence(of: current)
                )
            )
        }

        for piece in pieces {
            guard isTextBearing(piece.text) else { continue }
            if startsWord(piece.text), !current.isEmpty { flush() }
            current.append(piece)
        }
        flush()
        return words
    }

    // MARK: - The rules, one function each

    /// Whether a piece begins a new word.
    public static func startsWord(_ piece: String) -> Bool {
        guard let first = piece.first else { return false }
        return first == wordBoundaryMarker || first == " "
    }

    /// The piece without its boundary marker. Only the first character is a marker;
    /// a `▁` anywhere else is part of the text and stays.
    public static func stripBoundaryMarker(_ piece: String) -> String {
        startsWord(piece) ? String(piece.dropFirst()) : piece
    }

    /// Whether a piece is worth keeping.
    ///
    /// A bare boundary marker carries no text but is still kept: it says a new word
    /// begins, and dropping it would glue that word onto the previous one. Everything
    /// else that reduces to whitespace is dropped.
    public static func isTextBearing(_ piece: String) -> Bool {
        guard !piece.isEmpty, !controlPieces.contains(piece) else { return false }
        if startsWord(piece) { return true }
        return !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Mean confidence over the pieces that reported one, or `nil`.
    private static func meanConfidence(of pieces: [SubwordPiece]) -> Double? {
        let values = pieces.compactMap(\.confidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
