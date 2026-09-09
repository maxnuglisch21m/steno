import Foundation
import Testing

@testable import StenoCore

@Suite("RecordingFolderName")
struct RecordingFolderNameTests {
    /// 2026-09-09 14:30:12 +02:00, the timestamp the specification uses throughout.
    static let started = Date(timeIntervalSince1970: 1_788_957_012)
    static let berlin = TimeZone(secondsFromGMT: 7200)!

    @Test("builds the name from the specification")
    func specificationExamples() {
        #expect(
            RecordingFolderName.baseName(
                started: Self.started,
                mode: .online,
                appName: "Teams",
                timeZone: Self.berlin
            ) == "2026-09-09_1430_Teams"
        )
        #expect(
            RecordingFolderName.baseName(
                started: Self.started,
                mode: .onsite,
                timeZone: Self.berlin
            ) == "2026-09-09_1430_Vorort"
        )
    }

    @Test("appends the title slug")
    func titleSlug() {
        #expect(
            RecordingFolderName.baseName(
                started: Self.started,
                mode: .online,
                appName: "Teams",
                title: "Weekly Sync",
                timeZone: Self.berlin
            ) == "2026-09-09_1430_Teams_Weekly-Sync"
        )
    }

    @Test("an onsite recording ignores an app name it was given")
    func onsiteIgnoresAppName() {
        #expect(
            RecordingFolderName.label(mode: .onsite, appName: "Teams") == "Vorort"
        )
    }

    @Test("an online recording without an app name falls back to a label")
    func onlineWithoutAppName() {
        // `Online`, not `Meeting`: an `online` recording with no identifiable app is
        // a system-wide tap, and the folder name says what was recorded rather than
        // inventing an app that was never found.
        #expect(RecordingFolderName.unknownAppLabel == "Online")
        #expect(RecordingFolderName.label(mode: .online, appName: nil) == "Online")
        #expect(RecordingFolderName.label(mode: .online, appName: "") == "Online")
        #expect(RecordingFolderName.label(mode: .online, appName: "···") == "Online")
    }

    @Test("pads single-digit date and time components")
    func padsComponents() {
        // 2026-01-02 03:04:05 +00:00
        let early = Date(timeIntervalSince1970: 1_767_323_045)
        #expect(
            RecordingFolderName.baseName(
                started: early,
                mode: .onsite,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ) == "2026-01-02_0304_Vorort"
        )
    }

    @Test("renders the name in the given time zone")
    func timeZoneMatters() {
        let utc = RecordingFolderName.baseName(
            started: Self.started,
            mode: .onsite,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        #expect(utc == "2026-09-09_1230_Vorort")
    }

    // MARK: - Slugs

    @Test(
        "slugifies titles",
        arguments: [
            ("Weekly Sync", "Weekly-Sync"),
            ("Weekly  Sync", "Weekly-Sync"),
            ("  Weekly Sync  ", "Weekly-Sync"),
            ("Weekly Sync | Microsoft Teams", "Weekly-Sync-Microsoft-Teams"),
            ("Q4/2026 Review", "Q4-2026-Review"),
            ("Jour fixe (Marketing)", "Jour-fixe-Marketing"),
            ("Rollout: Phase 2", "Rollout-Phase-2"),
            // Umlauts and ß are transliterated, not just stripped.
            ("Bräutigam", "Braeutigam"),
            ("Öffnungszeiten", "Oeffnungszeiten"),
            ("Übergabe", "Uebergabe"),
            ("Straße", "Strasse"),
            ("Käse-Öl-Übung", "Kaese-Oel-Uebung"),
            // Other diacritics lose the mark.
            ("Café Résumé", "Cafe-Resume"),
            ("Señor Muñoz", "Senor-Munoz"),
            // Already clean input is left alone.
            ("Teams", "Teams"),
            ("v1.2", "v1-2")
        ]
    )
    func slugifies(title: String, expected: String) {
        #expect(RecordingFolderName.slug(from: title) == expected)
    }

    @Test(
        "yields no slug when nothing usable remains",
        arguments: [nil, "", "   ", "---", "···", "•••", "🎉🎉"]
    )
    func emptySlug(title: String?) {
        #expect(RecordingFolderName.slug(from: title) == nil)
    }

    @Test("caps the slug at forty characters")
    func slugLengthCap() throws {
        let long = "Sehr langes Meeting mit vielen Beteiligten und noch mehr Themen"
        let unwrapped = try #require(RecordingFolderName.slug(from: long))
        #expect(unwrapped.count <= RecordingFolderName.maxTitleSlugLength)
        // The cut lands on a word boundary rather than mid-word.
        #expect(unwrapped == "Sehr-langes-Meeting-mit-vielen")
        #expect(!unwrapped.hasSuffix("-"))
    }

    @Test("cuts mid-word rather than throwing most of the budget away")
    func slugLengthCapWithoutBoundary() {
        // A single long word offers no boundary worth cutting at.
        let slug = RecordingFolderName.slug(from: String(repeating: "a", count: 60))
        #expect(slug == String(repeating: "a", count: 40))
    }

    @Test("honours a custom slug length")
    func customSlugLength() {
        #expect(RecordingFolderName.slug(from: "Weekly Sync Review", maxLength: 11) == "Weekly-Sync")
        #expect(RecordingFolderName.slug(from: "Weekly Sync", maxLength: 0) == nil)
    }

    // MARK: - Collisions

    @Test("returns the base name when nothing exists yet")
    func noCollision() {
        let name = RecordingFolderName.make(
            started: Self.started,
            mode: .onsite,
            timeZone: Self.berlin,
            exists: { _ in false }
        )
        #expect(name == "2026-09-09_1430_Vorort")
    }

    @Test("appends _2, then _3, on collision")
    func collisionSuffixes() {
        var taken: Set<String> = ["2026-09-09_1430_Vorort"]

        func next() -> String {
            let name = RecordingFolderName.make(
                started: Self.started,
                mode: .onsite,
                timeZone: Self.berlin,
                exists: { taken.contains($0) }
            )
            taken.insert(name)
            return name
        }

        #expect(next() == "2026-09-09_1430_Vorort_2")
        #expect(next() == "2026-09-09_1430_Vorort_3")
        #expect(next() == "2026-09-09_1430_Vorort_4")
    }

    @Test("the collision suffix follows the title slug")
    func collisionWithTitle() {
        let name = RecordingFolderName.make(
            started: Self.started,
            mode: .online,
            appName: "Teams",
            title: "Weekly Sync",
            timeZone: Self.berlin,
            exists: { $0 == "2026-09-09_1430_Teams_Weekly-Sync" }
        )
        #expect(name == "2026-09-09_1430_Teams_Weekly-Sync_2")
    }

    @Test("falls back to a unique name when every suffix is taken")
    func exhaustedSuffixes() {
        let name = RecordingFolderName.make(
            started: Self.started,
            mode: .onsite,
            timeZone: Self.berlin,
            exists: { !$0.contains("-") ? false : $0.count < 32 }
        )
        #expect(name.hasPrefix("2026-09-09_1430_Vorort_"))
        #expect(name != "2026-09-09_1430_Vorort")
    }

    @Test(
        "recognizes its own names again and nothing else",
        arguments: [
            ("2026-09-09_1430_Vorort", true),
            ("2026-09-09_1430_Teams", true),
            ("2026-09-09_1430_Teams_Weekly-Sync", true),
            ("2026-09-09_1430_Teams_2", true),
            ("2026-09-09_0000_Online", true),
            ("2026-09-09_2359_Online", true),
            ("2026-09-09_1430", false),
            ("2026-09-09_1430_", false),
            ("2026-9-09_1430_Teams", false),
            ("2026-13-09_1430_Teams", false),
            ("2026-09-32_1430_Teams", false),
            ("2026-09-09_2460_Teams", false),
            ("2026-09-09_1470_Teams", false),
            ("Screenshots", false),
            ("", false),
            (".DS_Store", false),
            ("_work", false)
        ]
    )
    func recognisesOwnNames(name: String, isRecording: Bool) {
        #expect(RecordingFolderName.matches(name) == isRecording)
    }

    @Test("every name it produces is a name it recognizes")
    func roundTripsThroughMatching() {
        let names = [
            RecordingFolderName.baseName(started: Self.started, mode: .onsite, timeZone: Self.berlin),
            RecordingFolderName.baseName(
                started: Self.started,
                mode: .online,
                appName: "Teams",
                title: "Weekly Sync",
                timeZone: Self.berlin
            ),
            RecordingFolderName.baseName(started: Self.started, mode: .online, timeZone: Self.berlin)
        ]
        for name in names {
            #expect(RecordingFolderName.matches(name), "\(name) should be recognized")
        }
    }

    @Test("reads the start time back out of a name, to the minute")
    func readsStartTimeBack() {
        let date = RecordingFolderName.startedDate(
            from: "2026-09-09_1430_Teams_Weekly-Sync",
            timeZone: Self.berlin
        )
        // The name carries no seconds, so it lands on the minute the recording began.
        #expect(date == Self.started.addingTimeInterval(-12))
        #expect(RecordingFolderName.startedDate(from: "nope", timeZone: Self.berlin) == nil)
    }

    @Test("reads the label back out of a name")
    func readsLabelBack() {
        #expect(RecordingFolderName.label(fromFolderName: "2026-09-09_1430_Vorort") == "Vorort")
        #expect(
            RecordingFolderName.label(fromFolderName: "2026-09-09_1430_Teams_Weekly-Sync") == "Teams"
        )
        #expect(RecordingFolderName.label(fromFolderName: "screens") == nil)
    }

    @Test("the produced name is safe as a single path component")
    func namesArePathSafe() {
        let names = [
            RecordingFolderName.baseName(
                started: Self.started,
                mode: .online,
                appName: "Google Chrome",
                title: "Meet – abc/def",
                timeZone: Self.berlin
            ),
            RecordingFolderName.baseName(
                started: Self.started,
                mode: .onsite,
                title: "Küche: Umbau?",
                timeZone: Self.berlin
            )
        ]
        for name in names {
            #expect(!name.contains("/"))
            #expect(!name.contains(":"))
            #expect(!name.contains("."))
            #expect(!name.hasPrefix("."))
            #expect(name.allSatisfy { $0.isASCII })
        }
    }
}
