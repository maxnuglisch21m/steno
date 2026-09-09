import Foundation
import Testing

@testable import StenoCore

@Suite("WatchedApp")
struct WatchedAppTests {
    @Test("the defaults are the watchlist from the specification")
    func defaultsMatchSpecification() {
        let identifiers = WatchedApp.defaults.map(\.bundleId)
        #expect(
            identifiers == [
                "com.microsoft.teams2",
                "com.microsoft.teams",
                "us.zoom.xos",
                "com.google.Chrome",
                "com.microsoft.edge",
                "com.apple.Safari",
                "app.zen-browser.zen"
            ]
        )
        #expect(WatchedApp.defaults.allSatisfy { !$0.name.isEmpty })
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test(
        "a bundle identifier needs two segments of letters, digits, and hyphens",
        arguments: [
            ("com.microsoft.teams2", true),
            ("app.zen-browser.zen", true),
            ("us.zoom.xos", true),
            ("a.b", true),
            ("Teams", false),
            ("", false),
            (".", false),
            ("com..teams", false),
            ("com.teams.", false),
            (".com.teams", false),
            ("com.micro soft.teams", false),
            ("com.teams/2", false),
            ("com.täams", false)
        ]
    )
    func bundleIdentifierValidation(candidate: String, isValid: Bool) {
        #expect(WatchedApp.isValidBundleIdentifier(candidate) == isValid)
    }

    @Test("an over-long identifier is rejected")
    func rejectsOverLongIdentifier() {
        let long = "com." + String(repeating: "a", count: 300)
        #expect(!WatchedApp.isValidBundleIdentifier(long))
    }

    @Test("normalizing trims whitespace and rejects what is left unusable")
    func normalizing() {
        #expect(WatchedApp.normalizedBundleIdentifier("  us.zoom.xos \n") == "us.zoom.xos")
        #expect(WatchedApp.normalizedBundleIdentifier("   ") == nil)
        #expect(WatchedApp.normalizedBundleIdentifier("Zoom") == nil)
    }

    @Test("inserting replaces an entry with the same identifier")
    func insertingReplaces() {
        let list = [WatchedApp(bundleId: "us.zoom.xos", name: "Zoom")]
        let updated = WatchedApp.inserting(bundleId: "us.zoom.xos", name: "Zoom Workplace", into: list)
        #expect(updated?.count == 1)
        #expect(updated?.first?.name == "Zoom Workplace")
    }

    @Test("inserting appends a new entry and falls back to the last segment as its name")
    func insertingAppends() {
        let updated = WatchedApp.inserting(bundleId: " com.brave.Browser ", name: "  ", into: [])
        #expect(updated?.count == 1)
        #expect(updated?.first?.bundleId == "com.brave.Browser")
        #expect(updated?.first?.name == "Browser")
    }

    @Test("inserting an unusable identifier reports failure instead of dropping it")
    func insertingRejects() {
        #expect(WatchedApp.inserting(bundleId: "Brave", name: "Brave", into: []) == nil)
    }

    @Test("a watchlist survives a JSON round trip")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(WatchedApp.defaults)
        let decoded = try JSONDecoder().decode([WatchedApp].self, from: data)
        #expect(decoded == WatchedApp.defaults)
    }

    // MARK: - Matching a process against a watch entry

    @Test(
        "a watch entry matches its own identifier and its helper processes",
        arguments: [
            ("com.google.Chrome", "com.google.Chrome", true),
            ("com.google.Chrome", "com.google.Chrome.helper", true),
            ("com.google.Chrome", "com.google.Chrome.helper.Renderer", true),
            ("com.microsoft.teams2", "com.microsoft.teams2", true),
            ("com.microsoft.teams2", "com.microsoft.teams2.helper.renderer", true),
            // The trailing dot is what keeps a different app with a longer name out.
            ("com.google.Chrome", "com.google.ChromeCanary", false),
            ("com.google.Chrome", "com.google.Chrome2", false),
            ("com.google.Chrome", "com.google", false),
            ("com.google.Chrome", "com.microsoft.edge", false),
            // Case is the bundle's business, not the watchlist's.
            ("com.google.chrome", "com.google.Chrome.helper", true),
            ("", "com.google.Chrome", false)
        ]
    )
    func prefixMatching(watched: String, process: String, expected: Bool) {
        #expect(WatchedApp.matches(watchedBundleId: watched, processBundleId: process) == expected)
    }

    @Test("a helper process is found in the watchlist under its parent entry")
    func entryForHelperProcess() throws {
        let entry = try #require(
            WatchedApp.entry(for: "com.google.Chrome.helper", in: WatchedApp.defaults)
        )
        #expect(entry.bundleId == "com.google.Chrome")
        #expect(entry.name == "Chrome")
        #expect(WatchedApp.entry(for: "com.apple.Music", in: WatchedApp.defaults) == nil)
    }

    @Test("the first matching watchlist entry wins")
    func entryOrder() {
        let watchlist = [
            WatchedApp(bundleId: "com.google.Chrome.beta", name: "Chrome Beta"),
            WatchedApp(bundleId: "com.google.Chrome", name: "Chrome")
        ]
        #expect(WatchedApp.entry(for: "com.google.Chrome.beta.helper", in: watchlist)?.name == "Chrome Beta")
        #expect(WatchedApp.entry(for: "com.google.Chrome.helper", in: watchlist)?.name == "Chrome")
    }
}
