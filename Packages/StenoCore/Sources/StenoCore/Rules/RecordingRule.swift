import Foundation

/// What a matching rule does when a meeting is detected.
public enum RecordingRuleAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Never record this meeting, and do not ask.
    case never
    /// Show the suggestion popup. The behaviour with no rule at all.
    case ask
    /// Start recording without asking.
    case always
}

/// A rule matched against the triggering app and the meeting title, so that
/// "never record the daily standup" and "always record the client call" do not need a
/// click every time.
///
/// Rules are evaluated once, when the ≥ 5 s detection trigger fires. The title comes
/// from the triggering process's window (`Weekly Sync | Microsoft Teams`) and, if the
/// user opted in, from the calendar event currently running — which is the only way
/// to get a title out of Zoom, whose window says nothing but "Zoom Meeting", or a
/// Google Meet tab, which shows the meeting code.
public struct RecordingRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Bundle identifier this rule is limited to. `nil` matches any app.
    public var appBundleId: String?
    /// What to look for in the title. A case-insensitive substring, or a regular
    /// expression when `isRegex` is set. Empty matches any title, which makes the rule
    /// depend on `appBundleId` alone.
    public var pattern: String
    public var isRegex: Bool
    public var action: RecordingRuleAction
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        appBundleId: String? = nil,
        pattern: String,
        isRegex: Bool = false,
        action: RecordingRuleAction = .ask,
        enabled: Bool = true
    ) {
        self.id = id
        self.appBundleId = appBundleId
        self.pattern = pattern
        self.isRegex = isRegex
        self.action = action
        self.enabled = enabled
    }

    /// Whether this rule ignores the title and matches on the app alone.
    public var isAppOnly: Bool {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
