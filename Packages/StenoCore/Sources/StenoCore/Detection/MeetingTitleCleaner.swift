import Foundation

/// Turns a window title into a meeting title, or says that it is not one.
///
/// Window titles are the only place a meeting name is written down without asking the
/// calendar for it, and every app decorates them: Teams appends ` | Microsoft Teams`,
/// a browser appends ` - Google Chrome` and prefixes an unread count, Zoom writes
/// nothing but `Zoom Meeting` at all. So a raw title is worth two things — the
/// decoration removed, and a plain answer to "does this actually name a meeting?",
/// because a rule matched against `Microsoft Teams` would fire on every Teams call
/// ever made and a folder called `…_Zoom-Meeting` says nothing.
///
/// Pure string work, so the whole table is a test rather than something to be found
/// out during a real call.
public enum MeetingTitleCleaner {
    /// The app names that appear as a window-title suffix, longest first so that
    /// `Microsoft Teams` is tried before `Teams`.
    ///
    /// Matching is case-insensitive; the strings are written the way the app writes
    /// them so the list stays readable.
    public static let appNames: [String] = [
        "Microsoft Teams (classic)",
        "Microsoft Teams classic",
        "Microsoft Teams",
        "Microsoft Edge",
        "Mozilla Firefox",
        "Google Chrome",
        "Google Meet",
        "Zoom Workplace",
        "Cisco Webex",
        "Zen Browser",
        "Chromium",
        "Firefox",
        "Webex",
        "Teams",
        "Chrome",
        "Safari",
        "Zoom",
        "Edge",
        "Meet",
        "Zen"
    ]

    /// The separators an app puts between the title and its own name.
    ///
    /// Both dashes are here on purpose: Chrome uses a hyphen, Firefox an em dash, and
    /// Zoom an en dash, and a list that knows only one of them leaves half the titles
    /// decorated.
    public static let separators: [String] = [" | ", " - ", " – ", " — ", " · ", " • "]

    /// Titles that name an app rather than a meeting.
    ///
    /// Lowercased, and compared after cleaning, so `Zoom Meeting` and a bare `Teams`
    /// both land here. A generic title is not used for a folder name, is not written
    /// to `meta.json`, and does not end the title search early.
    public static let genericTitles: Set<String> = [
        "microsoft teams", "teams", "teams classic", "microsoft teams classic",
        "zoom", "zoom meeting", "zoom workplace", "zoom cloud meetings",
        "meet", "google meet", "webex", "cisco webex", "webex meetings",
        "google chrome", "chrome", "chromium", "microsoft edge", "edge",
        "safari", "mozilla firefox", "firefox", "zen", "zen browser",
        "meeting", "besprechung", "neuer tab", "new tab", "startseite", "start page",
        "untitled", "ohne titel"
    ]

    /// A Google Meet room code — `abc-defg-hij`. Meet puts it in the tab title in
    /// place of the meeting name, and it is a room identifier, not a title.
    /// Computed rather than stored: a `Regex` is not `Sendable`, and a static
    /// constant holding one would be shared mutable state. Compiling it costs
    /// microseconds and happens at most once every few seconds.
    private static var meetCode: Regex<Substring> { /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/ }

    /// A browser's unread badge: `(3) Weekly Sync`.
    private static var unreadBadge: Regex<Substring> { /^\(\d+\)\s*/ }

    // MARK: - Cleaning

    /// Strips the decoration an app adds, and returns what is left.
    ///
    /// Returns `nil` when nothing is left, which is what a title consisting entirely
    /// of the app's own name comes to.
    public static func clean(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacing(unreadBadge, with: "")

        // Repeatedly, because a Meet tab in Chrome carries both:
        // "Weekly Sync - Google Meet - Google Chrome".
        var didStrip = true
        var passes = 0
        while didStrip, passes < 4 {
            didStrip = false
            passes += 1
            for separator in separators {
                for app in appNames where title.count > separator.count + app.count {
                    let suffix = separator + app
                    guard title.lowercased().hasSuffix(suffix.lowercased()) else { continue }
                    title = String(title.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    didStrip = true
                    break
                }
                if didStrip { break }
            }
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Whether a title names an app or a room rather than a meeting.
    public static func isGeneric(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.isEmpty { return true }
        if genericTitles.contains(normalized) { return true }
        return normalized.wholeMatch(of: meetCode) != nil
    }

    /// The cleaned title, or `nil` when it is decoration, an app name, or a room code.
    ///
    /// This is what detection actually asks for: a title good enough to name a folder,
    /// match a rule against, and put in the suggestion popup.
    public static func usableTitle(_ raw: String) -> String? {
        guard let cleaned = clean(raw), !isGeneric(cleaned) else { return nil }
        return cleaned
    }

    /// The first usable title among several windows, in the order they were given.
    ///
    /// The caller sorts windows by area, so "first" means "the biggest window that
    /// says something" — which is the meeting window and not the notification banner
    /// floating in front of it.
    public static func best(of raws: [String]) -> String? {
        for raw in raws {
            if let title = usableTitle(raw) { return title }
        }
        return nil
    }
}
