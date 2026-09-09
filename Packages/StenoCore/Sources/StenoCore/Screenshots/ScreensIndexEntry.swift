import Foundation

/// One line of `screens.jsonl`:
///
/// ```json
/// {"t":18.42,"file":"screens/143012_d1_active.jpg","display":1,"active":true,"changed":0.31}
/// ```
///
/// `t` is seconds since the start of the recording. It is the bridge a downstream
/// tool uses to line a screenshot up with a transcript line, which is why the index
/// is appended to immediately on every save rather than written at the end.
public struct ScreensIndexEntry: Codable, Sendable, Hashable {
    /// The directory screenshots live in, relative to the meeting folder.
    public static let directoryName = "screens"

    /// Seconds since the recording started.
    public var t: TimeInterval
    /// Path relative to the meeting folder, including the `screens/` prefix.
    public var file: String
    /// The display's index, matching `MeetingMeta.displays[].index`.
    public var display: Int
    /// Whether this display held the mouse when the frame was captured.
    public var active: Bool
    /// Share of the display area that changed, 0…1.
    public var changed: Double

    public init(t: TimeInterval, file: String, display: Int, active: Bool, changed: Double) {
        self.t = t
        self.file = file
        self.display = display
        self.active = active
        self.changed = changed
    }

    /// Builds an entry, deriving `file` from the wall-clock time of the frame.
    public init(
        t: TimeInterval,
        capturedAt: Date,
        display: Int,
        active: Bool,
        changed: Double,
        timeZone: TimeZone = .current,
        sequence: Int = 1
    ) {
        self.init(
            t: t,
            file: Self.relativePath(
                capturedAt: capturedAt,
                display: display,
                active: active,
                timeZone: timeZone,
                sequence: sequence
            ),
            display: display,
            active: active,
            changed: changed
        )
    }

    /// Builds an entry around a file name that has already been made unique.
    public init(
        t: TimeInterval,
        fileName: String,
        display: Int,
        active: Bool,
        changed: Double
    ) {
        self.init(
            t: t,
            file: Self.directoryName + "/" + fileName,
            display: display,
            active: active,
            changed: changed
        )
    }

    // MARK: - File names

    /// `HHmmss_d<index>[_active].jpg` — for example `143012_d1_active.jpg`.
    ///
    /// - Parameter sequence: which frame of that display this is within the same
    ///   wall-clock second. `1` is the first and carries no suffix; a second frame in
    ///   the same second becomes `143012_d1_active_2.jpg`. The clock only has a
    ///   second's resolution and a display is captured at 1 fps, so a collision needs
    ///   a frame arriving just either side of a second boundary — rare, and silently
    ///   overwriting the earlier image would lose a screenshot the index still names.
    public static func fileName(
        capturedAt: Date,
        display: Int,
        active: Bool,
        timeZone: TimeZone = .current,
        sequence: Int = 1
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: capturedAt)
        let clock = String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let suffix = sequence > 1 ? "_\(sequence)" : ""
        return "\(clock)_d\(display)\(active ? "_active" : "")\(suffix).jpg"
    }

    /// The same name, prefixed with `screens/` as it appears in the index.
    public static func relativePath(
        capturedAt: Date,
        display: Int,
        active: Bool,
        timeZone: TimeZone = .current,
        sequence: Int = 1
    ) -> String {
        directoryName + "/" + fileName(
            capturedAt: capturedAt,
            display: display,
            active: active,
            timeZone: timeZone,
            sequence: sequence
        )
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
    public var jsonLine: String {
        let escapedFile = Self.escape(file)
        return """
        {"t":\(Self.number(t)),"file":"\(escapedFile)","display":\(display),\
        "active":\(active),"changed":\(Self.number(changed))}
        """
    }

    /// The line plus its newline, ready to append to `screens.jsonl`.
    public var jsonLineData: Data {
        Data((jsonLine + "\n").utf8)
    }

    /// Parses one line of `screens.jsonl`.
    public static func decode(line: String) throws -> ScreensIndexEntry {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONDecoder().decode(ScreensIndexEntry.self, from: Data(trimmed.utf8))
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
