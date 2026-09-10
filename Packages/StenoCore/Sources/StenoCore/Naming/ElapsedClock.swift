import Foundation

/// The one place a time offset from the start of a recording becomes a clock string.
///
/// Two files count from `meta.started` and both show it as a clock: `transcript.md`
/// puts `[HH:MM:SS]` in front of every utterance, and a screenshot's file name carries
/// the same clock with the colons removed (`HHMMSS_d1_active.jpg`). They have to agree
/// to the second — lining a screenshot up against what was being said is the whole
/// point of both — so they are formatted here rather than twice.
///
/// Hours count upwards instead of wrapping at 24, and the seconds are floored rather
/// than rounded: a frame at `t` 5.99 belongs to the transcript line stamped
/// `[00:00:05]`, not to the one after it.
public enum ElapsedClock: Sendable {
    /// `HH:MM:SS` — `00:00:05`, `01:02:03`, and `100:00:00` for a very long meeting.
    ///
    /// A negative or non-finite offset becomes `00:00:00`: neither can happen from a
    /// recording that has a start, and neither is worth a crash if it does.
    public static func string(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// The same clock without the colons, as a file name carries it: `000005`,
    /// `010203`. A colon is legal in a macOS file name and shows up as a slash in the
    /// Finder, which is why the file names drop them.
    public static func compact(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        return String(format: "%02d%02d%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// The offset in whole seconds, floored, never negative.
    ///
    /// Capped at a hundred years so that a nonsense offset — a `started` read from a
    /// corrupted `meta.json`, say — formats as a long clock instead of trapping on the
    /// conversion to `Int`.
    public static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds, 0), 3_155_760_000).rounded(.down))
    }
}
