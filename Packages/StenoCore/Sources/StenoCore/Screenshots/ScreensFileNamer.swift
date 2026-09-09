import Foundation

/// Hands out the screenshot file names, and makes sure no two frames get the same one.
///
/// The name in the specification carries a wall clock with a second's resolution
/// (`HHmmss_d<index>[_active].jpg`). Two frames of the same display can land in the
/// same second — the mouse moving onto a display changes the `_active` part of the
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

    private let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    /// The next unused name for a frame of `display` captured at `capturedAt`.
    public mutating func nextFileName(
        capturedAt: Date,
        display: Int,
        active: Bool
    ) -> String {
        // The clock string is the collision key, because it is exactly what the name
        // encodes: two instants 300 ms apart may or may not share a second.
        let clock = Self.clock(capturedAt, timeZone: timeZone)
        var sequence = 1
        if let previous = lastSecond[display], previous.clock == clock {
            sequence = previous.count + 1
        }
        lastSecond[display] = (clock, sequence)
        return ScreensIndexEntry.fileName(
            capturedAt: capturedAt,
            display: display,
            active: active,
            timeZone: timeZone,
            sequence: sequence
        )
    }

    /// Forgets a display, so one unplugged and plugged back in starts clean.
    public mutating func forget(display: Int) {
        lastSecond[display] = nil
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
