import Foundation

/// Picks the rule that applies to a detected meeting.
///
/// First match wins, in the order the user arranged them, so the rule list reads
/// top to bottom like a firewall and a specific rule can be put above a general one.
/// A rule with a broken regular expression matches nothing — a typo in Settings must
/// not silently turn into "record everything" or "record nothing".
public enum RuleMatcher {
    /// The first enabled rule matching this app and any of these titles.
    ///
    /// - Parameters:
    ///   - rules: the user's rules, in evaluation order.
    ///   - bundleId: bundle identifier of the triggering app, if known.
    ///   - titles: every title found for the meeting — window titles, and the calendar
    ///     event when that is enabled. A rule matches if *any* of them matches, because
    ///     the title is read repeatedly while the meeting app settles (a Teams pre-join
    ///     screen carries a different title than the meeting itself).
    public static func firstMatch(
        in rules: [RecordingRule],
        bundleId: String?,
        titles: [String]
    ) -> RecordingRule? {
        rules.first { matches($0, bundleId: bundleId, titles: titles) }
    }

    /// The action to take, or `nil` if no rule applies and the caller should fall back
    /// to its own default — the suggestion popup.
    public static func action(
        in rules: [RecordingRule],
        bundleId: String?,
        titles: [String]
    ) -> RecordingRuleAction? {
        firstMatch(in: rules, bundleId: bundleId, titles: titles)?.action
    }

    /// Whether one rule applies. Disabled rules never do.
    public static func matches(
        _ rule: RecordingRule,
        bundleId: String?,
        titles: [String]
    ) -> Bool {
        guard rule.enabled else { return false }

        if let ruleBundleId = rule.appBundleId {
            guard let bundleId, bundleId.caseInsensitiveCompare(ruleBundleId) == .orderedSame else {
                return false
            }
        }

        // An empty pattern makes the rule depend on the app alone, so it matches even
        // when no title could be read at all — which is the normal case for Zoom.
        guard !rule.isAppOnly else { return true }

        return titles.contains { matches(pattern: rule.pattern, isRegex: rule.isRegex, title: $0) }
    }

    /// Whether one title matches one pattern. Case-insensitive in both modes.
    public static func matches(pattern: String, isRegex: Bool, title: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        guard !title.isEmpty else { return false }

        if isRegex {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                // An invalid expression matches nothing, so a typo cannot change behaviour.
                return false
            }
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            return regex.firstMatch(in: title, options: [], range: range) != nil
        }

        return title.range(of: pattern, options: [.caseInsensitive]) != nil
    }

    /// Whether a pattern would compile. For validating the Settings field as it is typed.
    ///
    /// An empty pattern is valid in either mode: it means the rule matches on the app
    /// alone, and never reaches the expression engine — which would reject it.
    public static func isValidPattern(_ pattern: String, isRegex: Bool) -> Bool {
        guard isRegex, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }
}
