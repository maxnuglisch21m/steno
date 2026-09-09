import Foundation
import Testing

@testable import StenoCore

/// The window-title table.
///
/// Each of these is a title a real app puts on a real window, and the answer Steno has
/// to get out of it. They are cheap to write and they are the only place the
/// decoration rules are stated, so the list is long on purpose.
@Suite("MeetingTitleCleaner")
struct MeetingTitleCleanerTests {
    @Test(
        "app decoration is stripped",
        arguments: [
            ("Weekly Sync | Microsoft Teams", "Weekly Sync"),
            ("Weekly Sync - Microsoft Teams", "Weekly Sync"),
            ("Kickoff Centerplan | Microsoft Teams", "Kickoff Centerplan"),
            ("Jour fixe – Zoom", "Jour fixe"),
            ("Retro — Mozilla Firefox", "Retro"),
            ("Design Review - Google Chrome", "Design Review"),
            ("Design Review - Google Meet - Google Chrome", "Design Review"),
            ("Sprint Planning - Microsoft Edge", "Sprint Planning"),
            ("Standup - Zen", "Standup"),
            ("Kundentermin · Webex", "Kundentermin"),
            ("(3) Weekly Sync | Microsoft Teams", "Weekly Sync"),
            ("  Weekly Sync | Microsoft Teams  ", "Weekly Sync")
        ]
    )
    func stripsDecoration(raw: String, expected: String) {
        #expect(MeetingTitleCleaner.clean(raw) == expected)
        #expect(MeetingTitleCleaner.usableTitle(raw) == expected)
    }

    @Test(
        "a title that is only the app's name is not a meeting title",
        arguments: [
            "Microsoft Teams",
            "Teams",
            "Zoom",
            "Zoom Meeting",
            "Zoom Workplace",
            "Meet",
            "Google Meet",
            "Google Chrome",
            "Safari",
            "Mozilla Firefox",
            "Zen",
            "Microsoft Edge",
            "Webex",
            "Besprechung",
            "Meeting",
            "Neuer Tab",
            "New Tab",
            "",
            "   "
        ]
    )
    func genericTitles(raw: String) {
        #expect(MeetingTitleCleaner.usableTitle(raw) == nil)
    }

    @Test("a Google Meet room code is not a title")
    func meetRoomCode() {
        #expect(MeetingTitleCleaner.isGeneric("abc-defg-hij"))
        #expect(MeetingTitleCleaner.usableTitle("abc-defg-hij - Google Chrome") == nil)
        // A real title that merely looks similar survives.
        #expect(MeetingTitleCleaner.usableTitle("abc-defgh-ij") == "abc-defgh-ij")
    }

    @Test("case does not matter when stripping")
    func caseInsensitive() {
        #expect(MeetingTitleCleaner.clean("Weekly Sync | MICROSOFT TEAMS") == "Weekly Sync")
        #expect(MeetingTitleCleaner.isGeneric("mICROSOFT tEAMS"))
    }

    @Test("a hyphen inside the title is not a separator")
    func keepsInternalHyphens() {
        #expect(MeetingTitleCleaner.usableTitle("Q3 Review - Nord | Microsoft Teams") == "Q3 Review - Nord")
        #expect(MeetingTitleCleaner.usableTitle("Follow-up Rollout") == "Follow-up Rollout")
    }

    @Test("an app name inside the title is left alone")
    func keepsAppNameInsideTitle() {
        #expect(MeetingTitleCleaner.usableTitle("Teams Migration | Microsoft Teams") == "Teams Migration")
        #expect(MeetingTitleCleaner.usableTitle("Zoom vs Teams") == "Zoom vs Teams")
    }

    @Test("the best of several windows is the first one that says something")
    func bestOfSeveral() {
        let titles = ["Microsoft Teams", "Benachrichtigung", "Weekly Sync | Microsoft Teams"]
        #expect(MeetingTitleCleaner.best(of: titles) == "Benachrichtigung")
        #expect(MeetingTitleCleaner.best(of: ["Microsoft Teams", "Zoom"]) == nil)
        #expect(MeetingTitleCleaner.best(of: []) == nil)
    }

    @Test("cleaning never strips a title down to nothing")
    func neverEmpty() {
        // Stripping stops before it would leave an empty string, so a window whose
        // title is only the app's name keeps it — and `isGeneric` is what rejects it.
        #expect(MeetingTitleCleaner.clean("Microsoft Teams") == "Microsoft Teams")
        #expect(MeetingTitleCleaner.clean("   ") == nil)
        #expect(MeetingTitleCleaner.clean("(7)") == nil)
    }
}
