import EventKit
import Foundation

/// The title of the calendar event that is running right now.
///
/// The second title source, and the only one that works for Zoom and Google Meet,
/// whose windows carry a product name and a room code rather than a meeting name.
/// Specification §2 rejects the calendar as a *detection* signal and that stands:
/// nothing here starts a recording. This runs after detection has already fired, and
/// only ever answers the question "what is this meeting called".
///
/// Two gates, both of which must be open, and neither of which this file ever opens
/// itself:
///
/// 1. `settings.useCalendarTitles`, off by default. Reading someone's calendar to name
///    a folder is not a thing to do quietly.
/// 2. `EKEventStore.authorizationStatus(for: .event) == .fullAccess`. Access is
///    requested in exactly one place — the Settings toggle — because a permission
///    prompt that appears while a meeting starts is a permission prompt shown at the
///    worst possible moment, and one that appears at launch is worse still.
///
/// `authorizationStatus` is a read, never a prompt.
///
/// **Nothing here runs at launch, and it was checked.** `import EventKit` links
/// EventKit, which in turn links Contacts and `TCC.framework`, so the obvious worry is
/// that merely loading the framework makes `tccd` compute a prompting policy for
/// Calendar and Contacts before the user has agreed to anything. Measured on macOS 26.6
/// with
///
/// ```sh
/// log show --predicate 'process == "tccd"' --start "<launch>" | grep de.21m.steno
/// ```
///
/// across a direct launch, a Launch Services launch, and a launch with the settings
/// window open: the only services that appear are `kTCCServiceMicrophone`,
/// `kTCCServiceAudioCapture`, `kTCCServiceScreenCapture`, and `kTCCServiceListenEvent`.
/// No `kTCCServiceAddressBook`, no `kTCCServiceCalendar`. Those two do appear — twice
/// per run — when the app is launched as an XCTest host, where the injected test
/// frameworks are what touch Contacts; that is the test rig, not Steno, and no shipped
/// build ever loads them.
///
/// So the two gates below are the whole of it, and `&&` short-circuiting is load
/// bearing: with the setting off, `authorizationStatus` is never even asked.
@MainActor
enum CalendarTitleReader {
    /// How far either side of "now" an event may sit and still count as the meeting
    /// that just started. Five minutes covers a call joined early and one joined late.
    static let window: TimeInterval = 5 * 60

    /// Words that mark an event as an actual video call, so that a fifteen-minute
    /// "Fokuszeit" blocked out over the top of a real meeting does not win.
    private static let videoCallHints = [
        "teams.microsoft.com", "zoom.us", "meet.google.com", "webex.com",
        "whereby.com", "gotomeet", "bluejeans", "chime.aws",
        "teams", "zoom", "meet", "webex"
    ]

    /// Whether Steno may read the calendar. A pure read of two flags; never prompts.
    static func isAvailable(useCalendarTitles: Bool) -> Bool {
        useCalendarTitles && authorizationStatus == .fullAccess
    }

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Asks macOS for calendar access.
    ///
    /// The one caller is the Settings toggle. Returns whether full access ended up
    /// being granted, so the toggle can put itself back if the user said no.
    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            Log.detection.notice("calendar access \(granted ? "granted" : "refused", privacy: .public)")
            return granted
        } catch {
            Log.detection.error(
                "calendar access request failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Reading

    /// The title of the event overlapping now, or `nil`.
    ///
    /// An event with a video-call link in its URL, location, or notes wins over one
    /// without; among equals, the one that started most recently wins, because that is
    /// the meeting that was just joined. All-day events are ignored: they are labels
    /// on a day, not meetings.
    static func currentTitle(
        useCalendarTitles: Bool,
        at date: Date = Date(),
        store: EKEventStore? = nil
    ) -> String? {
        guard isAvailable(useCalendarTitles: useCalendarTitles) else { return nil }
        let store = store ?? EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-window),
            end: date.addingTimeInterval(window),
            calendars: nil
        )
        let events = store.events(matching: predicate).filter { event in
            guard !event.isAllDay, event.status != .canceled else { return false }
            guard let start = event.startDate, let end = event.endDate else { return false }
            // Overlapping now, within the grace window at both ends.
            return start <= date.addingTimeInterval(window) && end >= date.addingTimeInterval(-window)
        }
        guard !events.isEmpty else { return nil }

        let best = events.max { left, right in
            let leftCall = isVideoCall(left)
            let rightCall = isVideoCall(right)
            if leftCall != rightCall { return rightCall }
            return (left.startDate ?? .distantPast) < (right.startDate ?? .distantPast)
        }
        guard let title = best?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        // Never the title itself: `Log`'s rule is that nothing about meeting content
        // reaches the unified log.
        Log.detection.info("calendar event title found")
        return title
    }

    private static func isVideoCall(_ event: EKEvent) -> Bool {
        let haystack = [
            event.url?.absoluteString,
            event.location,
            event.notes
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        guard !haystack.isEmpty else { return false }
        return videoCallHints.contains { haystack.contains($0) }
    }
}
