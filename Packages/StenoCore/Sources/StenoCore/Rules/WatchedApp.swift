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

    // MARK: - Matching a process against this entry

    /// Whether a process with this bundle identifier belongs to this watched app.
    ///
    /// Equality is not enough. Chrome, Edge, and Teams do not play or capture audio in
    /// the process the user launched: they hand it to a helper, and the helper carries
    /// a bundle identifier one segment longer — `com.google.Chrome.helper`,
    /// `com.microsoft.teams2.helper.renderer`. A watchlist entry therefore matches its
    /// own identifier and anything below it in the dotted namespace, and nothing else:
    /// the trailing dot is what keeps `com.google.ChromeCanary` out.
    ///
    /// Case-insensitive, because Core Audio reports the identifier as the bundle
    /// spells it and a watchlist typed by hand rarely agrees on capitalisation.
    public func matches(processBundleId: String) -> Bool {
        Self.matches(watchedBundleId: bundleId, processBundleId: processBundleId)
    }

    /// The same test, without an instance, so a bare identifier can be checked.
    public static func matches(watchedBundleId: String, processBundleId: String) -> Bool {
        guard !watchedBundleId.isEmpty else { return false }
        if processBundleId.caseInsensitiveCompare(watchedBundleId) == .orderedSame { return true }
        let prefix = watchedBundleId + "."
        return processBundleId.count > prefix.count
            && processBundleId.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame
    }

    /// The watchlist entry a process belongs to, in watchlist order.
    ///
    /// First match wins, so a more specific entry placed above a general one takes the
    /// process — which is the only way to watch one Chrome profile's helper without
    /// watching all of Chrome.
    public static func entry(for processBundleId: String, in watchlist: [WatchedApp]) -> WatchedApp? {
        watchlist.first { $0.matches(processBundleId: processBundleId) }
    }

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
