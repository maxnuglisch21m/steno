import Foundation

/// One app Steno watches for microphone use, as edited in Settings → Rules.
///
/// Detection is Core-Audio-only (specification §2): Steno asks which process is
/// reading the microphone and compares its bundle identifier against this list. The
/// display name is only ever shown to the user and used in the folder name, so it
/// carries no meaning for the match.
public struct WatchedApp: Codable, Sendable, Hashable, Identifiable {
    public var bundleId: String
    public var name: String

    /// The bundle identifier. One app appears at most once in a watchlist.
    public var id: String { bundleId }

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }

    /// The watchlist from specification §2, in that order.
    public static let defaults: [WatchedApp] = [
        WatchedApp(bundleId: "com.microsoft.teams2", name: "Teams"),
        WatchedApp(bundleId: "com.microsoft.teams", name: "Teams (classic)"),
        WatchedApp(bundleId: "us.zoom.xos", name: "Zoom"),
        WatchedApp(bundleId: "com.google.Chrome", name: "Chrome"),
        WatchedApp(bundleId: "com.microsoft.edge", name: "Edge"),
        WatchedApp(bundleId: "com.apple.Safari", name: "Safari"),
        WatchedApp(bundleId: "app.zen-browser.zen", name: "Zen")
    ]

    // MARK: - Bundle identifiers

    /// Whether a string is shaped like a bundle identifier, so that Settings can
    /// refuse a typo before it becomes a watchlist entry that never matches.
    ///
    /// The rule is deliberately the one Apple documents for `CFBundleIdentifier`
    /// rather than something stricter: at least two dot-separated segments, and only
    /// ASCII letters, digits, and hyphens inside a segment. `com.microsoft.teams2`
    /// and `app.zen-browser.zen` both pass; `Teams`, `com..teams`, and
    /// `com.micro soft.teams` do not.
    public static func isValidBundleIdentifier(_ candidate: String) -> Bool {
        guard candidate.count <= 255 else { return false }
        let segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        for segment in segments {
            guard !segment.isEmpty else { return false }
            guard segment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return false }
        }
        return true
    }

    /// Trims a user-typed identifier and returns it only if it is usable.
    public static func normalizedBundleIdentifier(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidBundleIdentifier(trimmed) ? trimmed : nil
    }

    /// Adds an entry, replacing one with the same identifier rather than duplicating it.
    ///
    /// Returns `nil` when the identifier is not usable, so a caller can report the
    /// reason instead of silently dropping the input.
    public static func inserting(
        bundleId: String,
        name: String,
        into list: [WatchedApp]
    ) -> [WatchedApp]? {
        guard let identifier = normalizedBundleIdentifier(bundleId) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = WatchedApp(
            bundleId: identifier,
            // An empty name is more confusing in a list than the identifier's last
            // segment, which is what the app is usually called anyway.
            name: trimmedName.isEmpty ? String(identifier.split(separator: ".").last ?? "") : trimmedName
        )
        var result = list
        if let index = result.firstIndex(where: { $0.bundleId == identifier }) {
            result[index] = entry
        } else {
            result.append(entry)
        }
        return result
    }
}
