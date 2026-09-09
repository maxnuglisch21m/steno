import Foundation

extension Transcript {
    /// How many decimals every time in `transcript.json` carries.
    ///
    /// The recognizer reports times to about eight milliseconds and the diarizer to
    /// about sixteen; both come out of `Double` arithmetic with a tail of binary noise
    /// that means nothing. Writing `12.300000000000001` would suggest a precision that
    /// is not there and would make two runs over the same audio diff for no reason, so
    /// the file carries centiseconds — the same two decimals `screens.jsonl` uses,
    /// which is what lets a reader line a screenshot up against a transcript line.
    public static let timeDecimals = 2

    /// The same transcript with every time rounded to `timeDecimals`.
    ///
    /// Applied just before writing, never during the merge: the merge's decisions —
    /// which segment covers a token's midpoint, whether a gap exceeds 0.8 s — are made
    /// on the full precision the models reported.
    public func roundingTimes(toPlaces places: Int = Transcript.timeDecimals) -> Transcript {
        Transcript(
            mode: mode,
            utterances: utterances.map { utterance in
                Utterance(
                    speaker: utterance.speaker,
                    start: Self.round(utterance.start, places),
                    end: Self.round(utterance.end, places),
                    text: utterance.text,
                    tokens: utterance.tokens.map { Token(t: Self.round($0.t, places), w: $0.w) }
                )
            },
            diarization: diarization.map {
                DiarSegment(
                    speaker: $0.speaker,
                    start: Self.round($0.start, places),
                    end: Self.round($0.end, places)
                )
            },
            models: models,
            confidence: Confidence(
                asrRoom: confidence.asrRoom.map { Self.round($0, places) },
                asrMic: confidence.asrMic.map { Self.round($0, places) }
            )
        )
    }

    /// Half-away-from-zero at `places` decimals, which is what `%.2f` does and what a
    /// reader comparing the file against a printed number will expect.
    static func round(_ value: TimeInterval, _ places: Int) -> TimeInterval {
        guard value.isFinite else { return 0 }
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }
}
