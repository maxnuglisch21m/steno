import Foundation

/// Hands out the screenshot file names, and makes sure no two frames get the same one.
///
/// A name carries the offset from `meta.started` as a clock with a second's resolution
/// (`HHMMSS_d<index>[_active].jpg`), which is the same string `transcript.md` puts in
/// front of the line that was being spoken. Two frames of the same display can land in
/// the same second — the mouse moving onto a display changes the `_active` part of the
/// name but the anchor rule can also fire twice around a second boundary — and the
/// second frame must not silently overwrite the first, because `screens.jsonl` already
/// names both. So a repeat within the same second gets `_2`, `_3`, and so on.
///
/// State is one entry per display, not a set of every name issued: a four-hour meeting
/// on three monitors would otherwise keep thousands of strings alive to answer a
/// question that only ever concerns the second just passed.
public struct ScreensFileNamer: Sendable {
    /// The last second a display was written in, and how many frames it holds.
    private var lastSecond: [Int: (clock: String, count: Int)] = [:]

    public init() {}

    /// The next unused name for a frame of `display` captured `elapsed` seconds into
    /// the recording.
    public mutating func nextFileName(
        elapsed: TimeInterval,
        display: Int,
        active: Bool
    ) -> String {
        // The clock string is the collision key, because it is exactly what the name
        // encodes: two instants 300 ms apart may or may not share a second.
        let clock = ElapsedClock.compact(elapsed)
        var sequence = 1
        if let previous = lastSecond[display], previous.clock == clock {
            sequence = previous.count + 1
        }
        lastSecond[display] = (clock, sequence)
        return ScreensIndexEntry.fileName(
            t: elapsed,
            display: display,
            active: active,
            sequence: sequence
        )
    }

    /// Forgets a display, so one unplugged and plugged back in starts clean.
    public mutating func forget(display: Int) {
        lastSecond[display] = nil
    }
}
