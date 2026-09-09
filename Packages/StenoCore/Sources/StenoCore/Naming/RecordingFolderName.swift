import Foundation

/// Builds the folder name for one recording: `2026-09-09_1430_Teams`, or
/// `2026-09-09_1430_Vorort` for a room recording, optionally followed by a slug of
/// the meeting title (`2026-09-09_1430_Teams_Weekly-Sync`).
///
/// The name is the only piece of user-visible text in `StenoCore`, and it stays
/// German (`Vorort`) because it is a file name in the user's recording folder, not
/// a localizable interface string.
public enum RecordingFolderName {
    /// The label used in place of an app name for `onsite` recordings.
    public static let onsiteLabel = "Vorort"
    /// The label used for an `online` recording whose triggering app is unknown —
    /// a manual start with nothing identifiable in a meeting, which is recorded with a
    /// system-wide tap and is therefore about the Mac rather than about one app.
    public static let unknownAppLabel = "Online"
    /// Upper bound on the title slug, in characters.
    public static let maxTitleSlugLength = 40
    /// How many collision suffixes to try before giving up. `_2` through `_999`.
    public static let maxCollisionSuffix = 999

    /// Builds a folder name, appending `_2`, `_3`, … until `exists` reports the name free.
    ///
    /// - Parameters:
    ///   - started: when the recording began; supplies the date and time part.
    ///   - mode: decides whether `appName` or `Vorort` is used.
    ///   - appName: display name of the triggering app, for `online` recordings.
    ///   - title: meeting title from a window or calendar event; slugified when present.
    ///   - timeZone: time zone the date and time are rendered in. The user's own by default.
    ///   - exists: reports whether a candidate name is already taken.
    public static func make(
        started: Date,
        mode: MeetingMode,
        appName: String? = nil,
        title: String? = nil,
        timeZone: TimeZone = .current,
        exists: (String) -> Bool = { _ in false }
    ) -> String {
        let base = baseName(
            started: started,
            mode: mode,
            appName: appName,
            title: title,
            timeZone: timeZone
        )
        guard exists(base) else { return base }
        for suffix in 2...maxCollisionSuffix {
            let candidate = "\(base)_\(suffix)"
            if !exists(candidate) { return candidate }
        }
        // Every suffix taken. Fall back to something that cannot collide rather than
        // returning a name the caller would fail to create.
        return "\(base)_\(UUID().uuidString.prefix(8))"
    }

    /// The name without any collision suffix.
    public static func baseName(
        started: Date,
        mode: MeetingMode,
        appName: String? = nil,
        title: String? = nil,
        timeZone: TimeZone = .current
    ) -> String {
        var name = "\(datePart(started, timeZone: timeZone))_\(timePart(started, timeZone: timeZone))"
        name += "_" + label(mode: mode, appName: appName)
        if let slug = slug(from: title) { name += "_" + slug }
        return name
    }

    /// The app or mode component: a sanitized app name for `online`, `Vorort` for `onsite`.
    public static func label(mode: MeetingMode, appName: String?) -> String {
        switch mode {
        case .onsite:
            return onsiteLabel
        case .online:
            guard let appName, let cleaned = slug(from: appName, maxLength: maxTitleSlugLength) else {
                return unknownAppLabel
            }
            return cleaned
        }
    }

    /// Turns a meeting title into a file-name-safe slug, or `nil` if nothing usable remains.
    ///
    /// German umlauts and `ß` are transliterated (`ä` → `ae`, `ß` → `ss`); other accented
    /// letters lose their diacritic (`é` → `e`). Everything that is not an ASCII letter or
    /// digit becomes a `-`, runs of `-` collapse, and the result is cut to `maxLength`
    /// characters at a `-` boundary where one is close enough to keep whole words.
    public static func slug(from title: String?, maxLength: Int = maxTitleSlugLength) -> String? {
        guard let title, maxLength > 0 else { return nil }

        var folded = ""
        folded.reserveCapacity(title.count + 8)
        for character in title {
            if let replacement = Self.transliterations[character] {
                folded += replacement
            } else {
                folded.append(character)
            }
        }
        // Strip the remaining diacritics: é → e, ñ → n.
        let stripped = folded.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))

        var slug = ""
        slug.reserveCapacity(stripped.count)
        var pendingSeparator = false
        for character in stripped {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.append(character)
            } else {
                pendingSeparator = true
            }
        }
        guard !slug.isEmpty else { return nil }
        return truncate(slug, to: maxLength)
    }

    // MARK: - Recognising a name again

    /// Whether a folder name is shaped like one Steno wrote:
    /// `YYYY-MM-DD_HHMM_<label>` with an optional `_<slug>` and an optional `_<n>`
    /// collision suffix.
    ///
    /// This is what keeps "the last meeting" and the crash-recovery scan from picking
    /// up whatever else happens to sit in the recording root.
    public static func matches(_ name: String) -> Bool {
        parse(name) != nil
    }

    /// The date and time encoded in a recording folder name, to the minute.
    ///
    /// Returns `nil` for a name that is not one of ours. The value is only as precise
    /// as the name — `meta.json` holds the exact start — but it is enough to sort
    /// folders without opening every one of them.
    public static func startedDate(from name: String, timeZone: TimeZone = .current) -> Date? {
        guard let parsed = parse(name) else { return nil }
        var components = DateComponents()
        components.year = parsed.year
        components.month = parsed.month
        components.day = parsed.day
        components.hour = parsed.hour
        components.minute = parsed.minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    /// The label part of a recording folder name — `Teams`, or `Vorort`.
    public static func label(fromFolderName name: String) -> String? {
        parse(name)?.label
    }

    private struct Parsed {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var label: String
    }

    private static func parse(_ name: String) -> Parsed? {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }

        let dateParts = parts[0].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard dateParts.count == 3,
              dateParts[0].count == 4, dateParts[1].count == 2, dateParts[2].count == 2,
              let year = digits(dateParts[0]),
              let month = digits(dateParts[1]), (1...12).contains(month),
              let day = digits(dateParts[2]), (1...31).contains(day)
        else { return nil }

        guard parts[1].count == 4, let clock = digits(parts[1]) else { return nil }
        let hour = clock / 100
        let minute = clock % 100
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        guard !parts[2].isEmpty else { return nil }
        return Parsed(
            year: year, month: month, day: day,
            hour: hour, minute: minute, label: parts[2]
        )
    }

    /// An all-digit component as a number. Rejects `+1`, `1e3`, and non-ASCII digits,
    /// which `Int(_:)` alone would let through in part.
    private static func digits(_ component: String) -> Int? {
        guard !component.isEmpty,
              component.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(component)
    }

    // MARK: - Private

    private static func truncate(_ slug: String, to maxLength: Int) -> String {
        guard slug.count > maxLength else { return slug }
        let cutIndex = slug.index(slug.startIndex, offsetBy: maxLength)
        let hardCut = String(slug[slug.startIndex..<cutIndex])

        // The cut already falls between two words, so it keeps them all whole.
        if slug[cutIndex] == "-" { return trimmingSeparators(hardCut) }

        // Otherwise back up to the previous word boundary — but only when that still
        // leaves most of the budget, rather than throwing away half a title to keep
        // one long word intact.
        if let lastSeparator = hardCut.lastIndex(of: "-") {
            let head = String(hardCut[hardCut.startIndex..<lastSeparator])
            if head.count * 2 >= maxLength { return trimmingSeparators(head) }
        }
        return trimmingSeparators(hardCut)
    }

    private static func trimmingSeparators(_ slug: String) -> String {
        var result = slug
        while result.hasSuffix("-") { result.removeLast() }
        while result.hasPrefix("-") { result.removeFirst() }
        return result
    }

    /// Expansions that stripping the diacritic alone would get wrong. Everything else
    /// is handled by `folding(options: .diacriticInsensitive)`.
    private static let transliterations: [Character: String] = [
        "ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss",
        "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ẞ": "Ss",
        "æ": "ae", "Æ": "Ae", "œ": "oe", "Œ": "Oe",
        "ø": "oe", "Ø": "Oe"
    ]

    private static func datePart(_ date: Date, timeZone: TimeZone) -> String {
        let c = components(of: date, timeZone: timeZone)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func timePart(_ date: Date, timeZone: TimeZone) -> String {
        let c = components(of: date, timeZone: timeZone)
        return String(format: "%02d%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func components(of date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}
