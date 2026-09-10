import Testing

@testable import Steno

/// App-hosted tests. Deliberately thin: everything worth testing thoroughly lives in
/// `Packages/StenoCore` and is covered by `swift test`, which needs no host app, no
/// permissions, and no hardware. What these check is that the shell around it is
/// wired up — the bundle builds, launches under a test host, and links its packages.
@Suite("Steno app")
struct SmokeTests {
    @Test("the app links every package it declares")
    func linksDependencies() {
        // Referencing these forces the FluidAudio, Sparkle, and StenoCore symbols to
        // be resolved at link time, so a broken package pin fails here.
        #expect(String(describing: Dependencies.updaterControllerType).contains("Updater"))
        #expect(Dependencies.coreScreenshotThresholds.anchorInterval == 120)
        #expect(!Dependencies.fluidAudioVersion.isEmpty)
        // Read off the embedded framework rather than written down, so this is also
        // the check that the reading works: an empty bundle would silently fall back
        // to the pinned literal, and the two agreeing is what says it did not.
        #expect(!Dependencies.sparkleVersion.isEmpty)
        #expect(Dependencies.sparkleVersion == Dependencies.pinnedSparkleVersion)
        #expect(Dependencies.summary.contains(Dependencies.sparkleVersion))
        #expect(Dependencies.summary.contains("Steno"))
    }

    @Test("the bundle reports a version")
    func bundleVersion() {
        #expect(!AppVersion.marketing.isEmpty)
        #expect(!AppVersion.build.isEmpty)
    }
}
