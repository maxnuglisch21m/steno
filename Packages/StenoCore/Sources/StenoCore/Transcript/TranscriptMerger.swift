import Foundation

/// Turns recognizer tokens and diarizer segments into utterances — the whole of
/// specification §5's merge step, and the one piece of Steno where two models'
/// disagreements have to be resolved by a rule rather than by a model.
///
/// The rules, in the order they apply:
///
/// 1. Each room token gets the speaker of the diarization segment covering its
///    **midpoint**; no covering segment means `UNKNOWN`. The midpoint is used because
///    token edges are exactly where the recognizer and the diarizer disagree.
/// 2. In `online` mode the microphone tokens become `ME` and win: a room token whose
///    midpoint falls inside a `ME` token's span is dropped, because it is the same
///    speech arriving twice. Physics beats the model — channel 1 *is* the user.
/// 3. Everything is sorted by start time.
/// 4. Consecutive tokens of the same speaker bundle into one utterance; a gap of more
///    than 0.8 s starts a new one.
/// 5. Diarized speakers are renamed `S1 … Sn` in order of first appearance, so the
///    labels read in the order the meeting happened rather than in whatever order the
///    clustering produced. `ME` and `UNKNOWN` keep their names.
public enum TranscriptMerger {
    /// A silence longer than this starts a new utterance, even for the same speaker.
    public static let defaultGapThreshold: TimeInterval = 0.8

    /// Merges one recognition pass per channel with the diarization of the room channel.
    ///
    /// - Parameters:
    ///   - mode: `online` enables the `ME` override; `onsite` ignores `micTokens`
    ///     entirely, because without a separate microphone channel there is no `ME`
    ///     to be had and guessing one would be a lie.
    ///   - roomTokens: recognized tokens of channel 0 — tapped system audio in
    ///     `online` mode, the room microphone in `onsite`.
    ///   - micTokens: recognized tokens of channel 1. `online` only.
    ///   - diarization: the diarizer's segments for the room channel, labels as produced.
    ///   - models: model names, copied into the transcript.
    ///   - gapThreshold: silence that breaks an utterance.
    public static func merge(
        mode: MeetingMode,
        roomTokens: [ASRToken],
        micTokens: [ASRToken]? = nil,
        diarization: [DiarSegment],
        models: ModelIdentifiers,
        gapThreshold: TimeInterval = defaultGapThreshold
    ) -> Transcript {
        // `onsite` has no microphone channel, so any tokens handed in for one are ignored.
        let micTokens = mode.supportsSelfSpeaker ? (micTokens ?? []) : []
        let segments = diarization.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }

        // 1 + 2. Attach raw speakers to the room tokens the microphone did not already cover.
        let meSpans = micTokens.map { (start: $0.start, end: $0.end) }
        var labelled: [LabelledToken] = []
        labelled.reserveCapacity(roomTokens.count + micTokens.count)

        for (index, token) in roomTokens.enumerated() {
            let midpoint = token.midpoint
            let coveredByMe = meSpans.contains { midpoint >= $0.start && midpoint < $0.end }
            guard !coveredByMe else { continue }
            let speaker = segments.first { $0.covers(midpoint) }?.speaker ?? SpeakerLabel.unknown
            labelled.append(
                LabelledToken(token: token, rawSpeaker: speaker, source: .room, inputIndex: index)
            )
        }
        for (index, token) in micTokens.enumerated() {
            labelled.append(
                LabelledToken(
                    token: token,
                    rawSpeaker: SpeakerLabel.me,
                    source: .mic,
                    inputIndex: index
                )
            )
        }

        // 3. Sort by start. The remaining keys only exist to make the order total, so
        // that the same input always produces the same transcript.
        labelled.sort { lhs, rhs in
            if lhs.token.start != rhs.token.start { return lhs.token.start < rhs.token.start }
            if lhs.token.end != rhs.token.end { return lhs.token.end < rhs.token.end }
            if lhs.source != rhs.source { return lhs.source.rank < rhs.source.rank }
            return lhs.inputIndex < rhs.inputIndex
        }

        // 5. Number the diarized speakers by first appearance.
        var renaming: [String: String] = [:]
        var nextNumber = 1
        for entry in labelled where !SpeakerLabel.isReserved(entry.rawSpeaker) {
            if renaming[entry.rawSpeaker] == nil {
                renaming[entry.rawSpeaker] = SpeakerLabel.diarized(nextNumber)
                nextNumber += 1
            }
        }
        // A diarized speaker whose segments hold no tokens still needs a name, so that
        // the raw segments in the transcript are readable next to the utterances.
        for segment in segments where !SpeakerLabel.isReserved(segment.speaker) {
            if renaming[segment.speaker] == nil {
                renaming[segment.speaker] = SpeakerLabel.diarized(nextNumber)
                nextNumber += 1
            }
        }

        // 4. Bundle into utterances.
        var utterances: [Utterance] = []
        var current: [LabelledToken] = []
        var currentSpeaker: String?

        func flush() {
            guard let speaker = currentSpeaker, !current.isEmpty else { return }
            utterances.append(utterance(speaker: speaker, from: current))
            current.removeAll(keepingCapacity: true)
            currentSpeaker = nil
        }

        for entry in labelled {
            let speaker = renaming[entry.rawSpeaker] ?? entry.rawSpeaker
            if let currentSpeaker, let previous = current.last {
                let gap = entry.token.start - previous.token.end
                if speaker != currentSpeaker || gap > gapThreshold { flush() }
            }
            currentSpeaker = speaker
            current.append(entry)
        }
        flush()

        return Transcript(
            mode: mode,
            utterances: utterances,
            diarization: segments.map {
                DiarSegment(
                    speaker: renaming[$0.speaker] ?? $0.speaker,
                    start: $0.start,
                    end: $0.end
                )
            },
            models: models,
            confidence: Transcript.Confidence(
                asrRoom: meanConfidence(of: roomTokens),
                asrMic: mode.supportsSelfSpeaker ? meanConfidence(of: micTokens) : nil
            )
        )
    }

    /// Mean per-token confidence, ignoring tokens the recognizer gave none for.
    /// `nil` when there is nothing to average.
    ///
    /// This describes the recognition pass, not the merge, so it covers every token the
    /// recognizer produced — including room tokens that `ME` later displaced.
    public static func meanConfidence(of tokens: [ASRToken]) -> Double? {
        let values = tokens.compactMap(\.confidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Private

    private enum Source: Hashable {
        case mic
        case room

        /// Microphone tokens sort first at an identical timestamp: they are the source
        /// that wins everywhere else too.
        var rank: Int {
            switch self {
            case .mic: return 0
            case .room: return 1
            }
        }
    }

    private struct LabelledToken {
        var token: ASRToken
        var rawSpeaker: String
        var source: Source
        var inputIndex: Int
    }

    private static func utterance(speaker: String, from tokens: [LabelledToken]) -> Utterance {
        let words = tokens.map(\.token)
        return Utterance(
            speaker: speaker,
            start: words.first?.start ?? 0,
            // Tokens are ordered by start, so the last one need not hold the latest end.
            end: words.map(\.end).max() ?? 0,
            text: words.map(\.text).joined(separator: " "),
            tokens: words.map { Token(t: $0.start, w: $0.text) }
        )
    }
}
