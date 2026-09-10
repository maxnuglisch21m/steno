import Foundation
import StenoCore

/// Where a detected meeting's name comes from.
///
/// One protocol, so that `--simulate-detection` and the tests can hand a title in
/// without a window in sight — and so that the one caller, `MeetingDetectionController`,
/// never has to know that finding a title takes ten seconds.
@MainActor
protocol MeetingTitleSource {
    /// The meeting's name, or `nil` when the app never showed one.
    ///
    /// Takes as long as it takes; the caller runs it beside the suggestion rather than
    /// in front of it.
    func title(for meeting: DetectedMeeting) async -> String?
}

/// The real one: the triggering app's windows, read repeatedly while the app settles.
///
/// The calendar used to be the second source here, behind a setting and a permission.
/// It is gone: the popup no longer waits for a name, so the one thing the calendar
/// bought — a title for Zoom and Google Meet, whose windows carry a product name and a
/// room code — is not worth reading somebody's calendar for.
@MainActor
struct SystemMeetingTitleSource: MeetingTitleSource {
    /// Asked for an up-to-date process list between attempts: a browser spawns a new
    /// helper for the call after the trigger has already fired.
    var refreshPIDs: ((DetectedMeeting) -> [pid_t])?
    var timeout: TimeInterval = WindowTitleReader.searchTimeout

    func title(for meeting: DetectedMeeting) async -> String? {
        let refresh = refreshPIDs
        return await WindowTitleReader.resolveTitle(
            forPIDs: meeting.pids,
            refresh: refresh.map { refresh in { refresh(meeting) } },
            timeout: timeout
        )
    }
}

/// A title decided in advance, delivered after an optional delay. What the tests and
/// `--simulate-detection` use in place of a window that does not exist.
@MainActor
struct FixedMeetingTitleSource: MeetingTitleSource {
    var fixed: String?
    /// How long the fake search takes, so a test can check that the panel appears
    /// before the title does.
    var delay: Duration = .zero

    init(_ title: String?, delay: Duration = .zero) {
        if let title, !title.isEmpty {
            fixed = MeetingTitleCleaner.usableTitle(title) ?? title
        } else {
            fixed = nil
        }
        self.delay = delay
    }

    func title(for meeting: DetectedMeeting) async -> String? {
        if delay > .zero { try? await Task.sleep(for: delay) }
        return fixed
    }
}
