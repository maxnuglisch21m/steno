import Foundation

/// One line of `screens.jsonl`:
///
/// ```json
/// {"t":18.42,"at":"2026-09-09T14:30:30+02:00","file":"screens/000018_d1_active.jpg","display":1,"active":true,"changed":0.31}
/// ```
///
/// `t` is seconds since the start of the recording. It is the bridge a downstream
/// tool uses to line a screenshot up with a transcript line, which is why the index
/// is appended to immediately on every save rather than written at the end.
///
/// The file name carries the same offset as a clock, so `000018_d1_active.jpg` and the
/// transcript's `[00:00:18]` read as the same moment without anyone having to do
/// arithmetic. `at` carries the wall clock that name used to hold.
public struct ScreensIndexEntry: Codable, Sendable, Hashable {
    /// The directory screenshots live in, relative to the meeting folder.
    public static let directoryName = "screens"

    /// Seconds since the recording started.
    public var t: TimeInterval
    /// The wall clock at which the frame was captured, to the second.
    ///
    /// Optional because an index written before the file names counted from
    /// `meta.started` has no `at` at all, and a folder recorded by such a build must
    /// still decode — the recovery pass reads it.
    public var at: Date?
    /// Path relative to the meeting folder, including the `screens/` prefix.
    public var file: String
    /// The display's index, matching `MeetingMeta.displays[].index`.
    public var display: Int
    /// Whether this display held the mouse when the frame was captured.
    public var active: Bool
    /// Share of the display area that changed, 0…1.
    public var changed: Double

    public init(
        t: TimeInterval,
        at: Date? = nil,
        file: String,
        display: Int,
        active: Bool,
        changed: Double
    ) {
        self.t = t
        self.at = at
        self.file = file
        self.display = display
        self.active = active
        self.changed = changed
    }

    /// Builds an entry, deriving `file` from the offset the frame was captured at.
    public init(
        t: TimeInterval,
        at: Date? = nil,
        display: Int,
        active: Bool,
        changed: Double,
        sequence: Int = 1
    ) {
        self.init(
            t: t,
            at: at,
            file: Self.relativePath(t: t, display: display, active: active, sequence: sequence),
            display: display,
            active: active,
            changed: changed
        )
    }

    /// Builds an entry around a file name that has already been made unique.
    public init(
        t: TimeInterval,
        at: Date? = nil,
        fileName: String,
        display: Int,
        active: Bool,
        changed: Double
    ) {
        self.init(
            t: t,
            at: at,
            file: Self.directoryName + "/" + fileName,
            display: display,
            active: active,
            changed: changed
        )
    }

    // MARK: - File names

    /// `HHMMSS_d<index>[_active].jpg` — for example `000018_d1_active.jpg`.
    ///
    /// `HHMMSS` is `t` as a clock, floored to the second, formatted by `ElapsedClock` —
    /// the same helper `transcript.md` uses for its `[HH:MM:SS]`, so a screenshot and
    /// the line that was being spoken carry the same string. Hours count upwards rather
    /// than wrapping, so a five-hour meeting ends in `05…` and not back at `00…`.
    ///
    /// - Parameter sequence: which frame of that display this is within the same
    ///   second. `1` is the first and carries no suffix; a second frame in the same
    ///   second becomes `000018_d1_active_2.jpg`. The name only has a second's
    ///   resolution and a display is captured at 1 fps, so a collision needs a frame
    ///   arriving just either side of a second boundary — rare, and silently
    ///   overwriting the earlier image would lose a screenshot the index still names.
    public static func fileName(
        t: TimeInterval,
        display: Int,
        active: Bool,
        sequence: Int = 1
    ) -> String {
        let clock = ElapsedClock.compact(t)
        let suffix = sequence > 1 ? "_\(sequence)" : ""
        return "\(clock)_d\(display)\(active ? "_active" : "")\(suffix).jpg"
    }

    /// The same name, prefixed with `screens/` as it appears in the index.
    public static func relativePath(
        t: TimeInterval,
        display: Int,
        active: Bool,
        sequence: Int = 1
    ) -> String {
        directoryName + "/" + fileName(t: t, display: display, active: active, sequence: sequence)
    }

    /// The file name without the `screens/` prefix.
    public var fileName: String {
        let prefix = Self.directoryName + "/"
        return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
    }

    // MARK: - Serialization

    /// The entry as a single JSON line, without a trailing newline.
    ///
    /// Written by hand rather than through `JSONEncoder` for two reasons: the key
    /// order in the specification is preserved, and `t` and `changed` get two
    /// decimals instead of a full binary round-trip of a `Double`, which is what
    /// makes the file readable and its lines stable.
    ///
    /// - Parameter timeZone: the zone `at` is written in, the same one `meta.json`'s
    ///   timestamps use. An entry with no `at` — one read back off an index written by
    ///   an older build — writes the line without the key rather than inventing one.
    public func jsonLine(timeZone: TimeZone = .current) -> String {
        let escapedFile = Self.escape(file)
        let wallClock = at.map { #""at":"\#(ISO8601Timestamp.string(from: $0, timeZone: timeZone))","# } ?? ""
        return """
        {"t":\(Self.number(t)),\(wallClock)"file":"\(escapedFile)","display":\(display),\
        "active":\(active),"changed":\(Self.number(changed))}
        """
    }

    /// The line plus its newline, ready to append to `screens.jsonl`.
    public func jsonLineData(timeZone: TimeZone = .current) -> Data {
        Data((jsonLine(timeZone: timeZone) + "\n").utf8)
    }

    /// Parses one line of `screens.jsonl`.
    public static func decode(line: String) throws -> ScreensIndexEntry {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ISO8601Timestamp.decoder().decode(ScreensIndexEntry.self, from: Data(trimmed.utf8))
    }

    /// Parses a whole `screens.jsonl`, skipping blank lines.
    ///
    /// A recording that was interrupted mid-append can leave a truncated final line;
    /// `lenient` drops any line that fails to parse instead of failing the whole file.
    public static func decode(
        jsonl: String,
        lenient: Bool = false
    ) throws -> [ScreensIndexEntry] {
        var entries: [ScreensIndexEntry] = []
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if lenient {
                if let entry = try? decode(line: text) { entries.append(entry) }
            } else {
                entries.append(try decode(line: text))
            }
        }
        return entries
    }

    // MARK: - Repairing a truncated index

    /// How many leading bytes of a `screens.jsonl` form complete, parseable lines.
    ///
    /// The index is appended to and `synchronize()`d once per image, so a process that
    /// dies mid-append leaves at most one incomplete line — usually a fragment of JSON
    /// with no newline after it. `decode(jsonl:lenient:)` can read past that, but every
    /// other reader in the world cannot, and the file is meant to be readable by
    /// anything. So the recovery pass truncates the file to this length.
    ///
    /// A line counts as complete when it is terminated by a newline **and** parses. The
    /// newline requirement is what makes this safe: the terminator is written in the
    /// same `write(contentsOf:)` as the JSON, so a line that has one was written whole,
    /// and a final line without one is a fragment even in the rare case that the
    /// fragment happens to be valid JSON on its own.
    ///
    /// - Returns: a byte count in `0...data.count`. Equal to `data.count` when nothing
    ///   needs trimming, which is the normal case.
    public static func completeByteCount(ofJSONL data: some Collection<UInt8>) -> Int {
        let bytes = Array(data)
        let newline = UInt8(ascii: "\n")
        // Where the last newline is: everything after it is an unterminated fragment.
        guard var end = bytes.lastIndex(of: newline).map({ $0 + 1 }) else { return 0 }

        // Then walk back over terminated-but-unparseable lines. A partial write can be
        // interleaved with the newline of the line before it, which leaves a line that
        // ends properly and still holds half a record.
        while end > 0 {
            let previous = bytes[0..<(end - 1)].lastIndex(of: newline).map { $0 + 1 } ?? 0
            let line = String(decoding: bytes[previous..<end], as: UTF8.self)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || (try? decode(line: trimmed)) != nil { return end }
            end = previous
        }
        return 0
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.2f", value)
    }

    private static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if character.value < 0x20 {
                    result += String(format: "\\u%04x", character.value)
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result
    }
}
