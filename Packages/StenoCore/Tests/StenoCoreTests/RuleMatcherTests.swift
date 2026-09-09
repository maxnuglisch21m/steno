import Foundation
import Testing

@testable import StenoCore

@Suite("RuleMatcher")
struct RuleMatcherTests {
    static let teams = "com.microsoft.teams2"
    static let zoom = "us.zoom.xos"

    static func rule(
        app: String? = nil,
        _ pattern: String,
        regex: Bool = false,
        _ action: RecordingRuleAction = .never,
        enabled: Bool = true
    ) -> RecordingRule {
        RecordingRule(
            appBundleId: app,
            pattern: pattern,
            isRegex: regex,
            action: action,
            enabled: enabled
        )
    }

    // MARK: - Patterns

    @Test(
        "matches a substring, case-insensitively",
        arguments: [
            ("Standup", "Daily Standup | Microsoft Teams", true),
            ("standup", "Daily Standup | Microsoft Teams", true),
            ("STANDUP", "Daily Standup | Microsoft Teams", true),
            ("Daily Standup", "Daily Standup | Microsoft Teams", true),
            ("Microsoft Teams", "Daily Standup | Microsoft Teams", true),
            ("Weekly", "Daily Standup | Microsoft Teams", false),
            ("stand up", "Daily Standup | Microsoft Teams", false),
            // German titles match on their own terms.
            ("jour fixe", "Jour Fixe Marketing", true),
            ("Übergabe", "übergabe kunde", true),
            // Case-insensitive comparison folds the whole of Unicode, so ß and SS are
            // the same string. Convenient for German titles, and worth pinning down.
            ("Größe", "GRÖSSE", true),
            ("Grösse", "GRÖSSE", true)
        ]
    )
    func substringMatching(pattern: String, title: String, expected: Bool) {
        #expect(RuleMatcher.matches(pattern: pattern, isRegex: false, title: title) == expected)
    }

    @Test(
        "matches a regular expression, case-insensitively",
        arguments: [
            ("^Daily", "Daily Standup", true),
            ("^Daily", "Not Daily", false),
            ("^daily", "Daily Standup", true),
            ("Standup$", "Daily Standup", true),
            ("Standup$", "Daily Standup | Teams", false),
            ("(Weekly|Daily) Sync", "Weekly Sync", true),
            ("(Weekly|Daily) Sync", "Monthly Sync", false),
            ("KW\\s?\\d+", "Review KW 37", true),
            ("KW\\s?\\d+", "Review KW37", true),
            ("KW\\s?\\d+", "Review KW", false),
            (".*", "anything", true)
        ]
    )
    func regexMatching(pattern: String, title: String, expected: Bool) {
        #expect(RuleMatcher.matches(pattern: pattern, isRegex: true, title: title) == expected)
    }

    @Test(
        "an invalid regular expression matches nothing",
        arguments: ["[", "(unclosed", "*", "a{2,1}", "(?<", "\\"]
    )
    func invalidRegexMatchesNothing(pattern: String) {
        // A typo in the Settings field must not silently mean "record everything".
        #expect(!RuleMatcher.matches(pattern: pattern, isRegex: true, title: "anything at all"))
        #expect(!RuleMatcher.isValidPattern(pattern, isRegex: true))
        // The same text as a plain substring is a perfectly good pattern.
        #expect(RuleMatcher.isValidPattern(pattern, isRegex: false))
    }

    @Test("a valid regular expression is reported as valid")
    func validPatterns() {
        #expect(RuleMatcher.isValidPattern("^Daily.*Standup$", isRegex: true))
        #expect(RuleMatcher.isValidPattern("", isRegex: true))
        #expect(RuleMatcher.isValidPattern("[", isRegex: false))
    }

    @Test("regex metacharacters are literal in substring mode")
    func substringTreatsMetacharactersLiterally() {
        #expect(RuleMatcher.matches(pattern: "C++", isRegex: false, title: "Review C++ Port"))
        #expect(!RuleMatcher.matches(pattern: "^Daily", isRegex: false, title: "Daily Standup"))
        #expect(RuleMatcher.matches(pattern: "Q4/2026", isRegex: false, title: "Plan Q4/2026"))
    }

    @Test("an empty title matches nothing but an empty pattern")
    func emptyTitle() {
        #expect(!RuleMatcher.matches(pattern: "Standup", isRegex: false, title: ""))
        #expect(!RuleMatcher.matches(pattern: ".*", isRegex: true, title: ""))
        #expect(RuleMatcher.matches(pattern: "", isRegex: false, title: ""))
    }

    // MARK: - Rules

    @Test("a rule limited to an app only matches that app")
    func appScoping() {
        let rule = Self.rule(app: Self.teams, "Standup")
        #expect(RuleMatcher.matches(rule, bundleId: Self.teams, titles: ["Daily Standup"]))
        #expect(!RuleMatcher.matches(rule, bundleId: Self.zoom, titles: ["Daily Standup"]))
        #expect(!RuleMatcher.matches(rule, bundleId: nil, titles: ["Daily Standup"]))
    }

    @Test("the bundle identifier is compared case-insensitively")
    func bundleIdCaseInsensitive() {
        let rule = Self.rule(app: "com.microsoft.Teams2", "Standup")
        #expect(RuleMatcher.matches(rule, bundleId: "com.microsoft.teams2", titles: ["Standup"]))
    }

    @Test("a rule without an app matches every app")
    func appAgnosticRule() {
        let rule = Self.rule("Standup")
        #expect(RuleMatcher.matches(rule, bundleId: Self.teams, titles: ["Daily Standup"]))
        #expect(RuleMatcher.matches(rule, bundleId: Self.zoom, titles: ["Daily Standup"]))
        #expect(RuleMatcher.matches(rule, bundleId: nil, titles: ["Daily Standup"]))
    }

    @Test("an empty pattern makes the rule depend on the app alone")
    func appOnlyRule() {
        // The only way to catch Zoom, whose window says nothing but "Zoom Meeting".
        let rule = Self.rule(app: Self.zoom, "")
        #expect(rule.isAppOnly)
        #expect(RuleMatcher.matches(rule, bundleId: Self.zoom, titles: []))
        #expect(RuleMatcher.matches(rule, bundleId: Self.zoom, titles: ["Zoom Meeting"]))
        #expect(!RuleMatcher.matches(rule, bundleId: Self.teams, titles: ["Zoom Meeting"]))
    }

    @Test("a whitespace-only pattern counts as empty")
    func whitespacePatternIsAppOnly() {
        #expect(Self.rule("   ").isAppOnly)
        #expect(Self.rule("\t\n").isAppOnly)
        #expect(!Self.rule("a").isAppOnly)
    }

    @Test("any one of the titles is enough")
    func anyTitleMatches() {
        // The title is re-read while the meeting app settles: a Teams pre-join screen
        // carries a different title than the meeting itself.
        let rule = Self.rule(app: Self.teams, "Weekly Sync")
        #expect(
            RuleMatcher.matches(
                rule,
                bundleId: Self.teams,
                titles: ["Microsoft Teams", "Weekly Sync | Microsoft Teams"]
            )
        )
        #expect(
            !RuleMatcher.matches(rule, bundleId: Self.teams, titles: ["Microsoft Teams", "Chat"])
        )
    }

    @Test("no titles at all means a title rule cannot match")
    func noTitles() {
        #expect(!RuleMatcher.matches(Self.rule("Standup"), bundleId: Self.teams, titles: []))
    }

    @Test("a disabled rule never matches")
    func disabledRule() {
        let rule = Self.rule("Standup", .never, enabled: false)
        #expect(!RuleMatcher.matches(rule, bundleId: Self.teams, titles: ["Daily Standup"]))
        // Not even as an app-only rule.
        #expect(!RuleMatcher.matches(Self.rule(app: Self.zoom, "", enabled: false), bundleId: Self.zoom, titles: []))
    }

    // MARK: - Evaluation order

    @Test("the first matching rule wins")
    func firstMatchWins() throws {
        let rules = [
            Self.rule(app: Self.teams, "Standup", .never),
            Self.rule("Standup", .always),
            Self.rule("", .ask)
        ]
        #expect(RuleMatcher.action(in: rules, bundleId: Self.teams, titles: ["Daily Standup"]) == .never)
        // For any other app the second rule is the first to match.
        #expect(RuleMatcher.action(in: rules, bundleId: Self.zoom, titles: ["Daily Standup"]) == .always)
        // And the catch-all takes anything else.
        #expect(RuleMatcher.action(in: rules, bundleId: Self.zoom, titles: ["Kundentermin"]) == .ask)

        let matched = try #require(
            RuleMatcher.firstMatch(in: rules, bundleId: Self.teams, titles: ["Daily Standup"])
        )
        #expect(matched.id == rules[0].id)
    }

    @Test("a specific rule placed above a general one still wins")
    func orderIsRespected() {
        let specific = Self.rule(app: Self.teams, "Kundentermin", .always)
        let general = Self.rule(app: Self.teams, "", .never)
        #expect(
            RuleMatcher.action(in: [specific, general], bundleId: Self.teams, titles: ["Kundentermin ACME"])
                == .always
        )
        // Reversed, the general rule swallows it — which is what the ordering is for.
        #expect(
            RuleMatcher.action(in: [general, specific], bundleId: Self.teams, titles: ["Kundentermin ACME"])
                == .never
        )
    }

    @Test("a disabled rule is skipped rather than stopping evaluation")
    func disabledRuleIsSkipped() {
        let rules = [
            Self.rule(app: Self.teams, "Standup", .never, enabled: false),
            Self.rule("Standup", .always)
        ]
        #expect(RuleMatcher.action(in: rules, bundleId: Self.teams, titles: ["Daily Standup"]) == .always)
    }

    @Test("a rule with a broken expression is skipped, not obeyed")
    func brokenRuleIsSkipped() {
        let rules = [
            Self.rule(app: Self.teams, "[unclosed", regex: true, .never),
            Self.rule("Standup", .always)
        ]
        #expect(RuleMatcher.action(in: rules, bundleId: Self.teams, titles: ["Daily Standup"]) == .always)
    }

    @Test("no rules means no decision, so the caller falls back to asking")
    func noRules() {
        #expect(RuleMatcher.action(in: [], bundleId: Self.teams, titles: ["Daily Standup"]) == nil)
        #expect(RuleMatcher.firstMatch(in: [], bundleId: nil, titles: []) == nil)
    }

    @Test("no matching rule means no decision")
    func noMatch() {
        let rules = [Self.rule(app: Self.teams, "Standup", .never)]
        #expect(RuleMatcher.action(in: rules, bundleId: Self.zoom, titles: ["Daily Standup"]) == nil)
    }

    // MARK: - The rule itself

    @Test("a rule round-trips through Codable")
    func codable() throws {
        let rules = [
            RecordingRule(appBundleId: Self.teams, pattern: "Standup", action: .never),
            RecordingRule(pattern: "^Kunde", isRegex: true, action: .always, enabled: false),
            RecordingRule(pattern: "", action: .ask)
        ]
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode([RecordingRule].self, from: data) == rules)
    }

    @Test("defaults to asking, enabled, and any app")
    func defaults() {
        let rule = RecordingRule(pattern: "Standup")
        #expect(rule.action == .ask)
        #expect(rule.enabled)
        #expect(rule.appBundleId == nil)
        #expect(!rule.isRegex)
    }

    @Test("the actions encode as the names the settings use")
    func actionRawValues() {
        #expect(RecordingRuleAction.allCases.map(\.rawValue) == ["never", "ask", "always"])
    }

    @Test("each rule gets its own identity")
    func distinctIdentities() {
        let a = RecordingRule(pattern: "x")
        let b = RecordingRule(pattern: "x")
        #expect(a.id != b.id)
        #expect(a != b)
    }
}
