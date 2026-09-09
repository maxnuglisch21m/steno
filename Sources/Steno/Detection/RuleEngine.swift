import Foundation
import StenoCore

/// Every title found for one detected meeting.
struct MeetingTitles: Sendable, Equatable {
    /// Titles exactly as the app and the calendar wrote them, decoration and all.
    /// Rules are matched against these too, so a rule can say "Microsoft Teams".
    var raw: [String] = []
    /// The best title after cleaning — the one that names the folder, goes into
    /// `meta.json`, and appears in the popup. `nil` when nothing usable was found.
    var best: String?

    /// What the rule matcher sees: everything, cleaned and raw, without duplicates.
    var all: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for title in ([best].compactMap { $0 } + raw) where seen.insert(title).inserted {
            result.append(title)
        }
        return result
    }

    static let none = MeetingTitles()
}

/// Where a meeting's title comes from. One protocol so that `--simulate-detection` and
/// the tests can hand a title in without a window or a calendar in sight.
@MainActor
protocol MeetingTitleSource {
    func titles(for meeting: DetectedMeeting) async -> MeetingTitles
}

/// The real one: the triggering app's windows first, the running calendar event second.
///
/// Window titles come first because they describe *this* call, and because they cost
/// nothing and need no opt-in. The calendar is asked only when the window said nothing
/// usable — which is the Zoom and Google Meet case, and exactly what the setting was
/// added for.
@MainActor
struct SystemMeetingTitleSource: MeetingTitleSource {
    let settings: SettingsStore
    /// Asked for an up-to-date process list between attempts: a browser spawns a new
    /// helper for the call after the trigger has already fired.
    var refreshPIDs: ((DetectedMeeting) -> [pid_t])?
    var timeout: TimeInterval = WindowTitleReader.searchTimeout

    func titles(for meeting: DetectedMeeting) async -> MeetingTitles {
        var titles = MeetingTitles()
        let refresh = refreshPIDs
        let best = await WindowTitleReader.resolveTitle(
            forPIDs: meeting.pids,
            refresh: refresh.map { refresh in { refresh(meeting) } },
            timeout: timeout
        )
        titles.raw = WindowTitleReader.titles(forPIDs: meeting.pids)
        titles.best = best

        if titles.best == nil,
           let fromCalendar = CalendarTitleReader.currentTitle(
               useCalendarTitles: settings.settings.useCalendarTitles
           ) {
            titles.raw.append(fromCalendar)
            titles.best = MeetingTitleCleaner.usableTitle(fromCalendar) ?? fromCalendar
        }
        return titles
    }
}

/// What should happen with a detected meeting.
struct RuleDecision: Sendable, Equatable {
    var action: RecordingRuleAction
    /// The title to record and to show, if one was found.
    var title: String?
    /// Whether a rule actually matched, as opposed to `ask` being the default.
    var isFromRule: Bool
}

/// Turns a detected meeting plus its titles into never / ask / always.
///
/// The decision itself is `StenoCore.RuleMatcher` — first enabled match wins, in the
/// order the user arranged them. This adds the two things the matcher must not know
/// about: where titles come from, and that no match means the popup.
@MainActor
final class RuleEngine {
    private let settings: SettingsStore
    private var titleSource: any MeetingTitleSource

    init(settings: SettingsStore, titleSource: any MeetingTitleSource) {
        self.settings = settings
        self.titleSource = titleSource
    }

    #if DEBUG
    /// Hands the engine a title without a window to read it from.
    /// `--simulate-detection` and the tests, and nothing else.
    func useTitleSource(_ source: any MeetingTitleSource) {
        titleSource = source
    }
    #endif

    /// Looks for a title, then applies the rules.
    ///
    /// Takes as long as the title search does — up to ten seconds when the app shows
    /// nothing but its own name — because a rule that says "never record the daily
    /// standup" is worthless if the decision is made before the standup has a name.
    /// A joined Teams call answers on the first read and the popup appears at once.
    func decide(for meeting: DetectedMeeting) async -> RuleDecision {
        let titles = await titleSource.titles(for: meeting)
        return decide(for: meeting, titles: titles)
    }

    /// The pure half, for the tests: titles in, decision out.
    func decide(for meeting: DetectedMeeting, titles: MeetingTitles) -> RuleDecision {
        let matched = RuleMatcher.firstMatch(
            in: settings.settings.rules,
            bundleId: meeting.bundleId,
            titles: titles.all
        )
        let decision = RuleDecision(
            action: matched?.action ?? .ask,
            title: titles.best,
            isFromRule: matched != nil
        )
        Log.detection.notice(
            """
            rule decision for \(meeting.name, privacy: .public): \
            \(decision.action.rawValue, privacy: .public)\
            \(decision.isFromRule ? " (rule)" : " (no rule)", privacy: .public), \
            title \(decision.title == nil ? "unknown" : "known", privacy: .public)
            """
        )
        return decision
    }
}

/// A title decided in advance. What the tests and `--simulate-detection` use in place
/// of a window that does not exist.
@MainActor
struct FixedMeetingTitleSource: MeetingTitleSource {
    var titles: MeetingTitles

    init(_ title: String?) {
        if let title, !title.isEmpty {
            titles = MeetingTitles(raw: [title], best: MeetingTitleCleaner.usableTitle(title) ?? title)
        } else {
            titles = .none
        }
    }

    init(titles: MeetingTitles) {
        self.titles = titles
    }

    func titles(for meeting: DetectedMeeting) async -> MeetingTitles { titles }
}
