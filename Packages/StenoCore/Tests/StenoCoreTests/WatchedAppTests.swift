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
}
