import Foundation
import Testing

@testable import Steno

/// A class that exists only so `Bundle(for:)` can be pointed at the test bundle, which
/// has no `SUPublicEDKey` and therefore stands in for a build made before the first
/// release.
private final class TestBundleMarker: NSObject {}

/// The check that decides whether Sparkle is started at all.
///
/// It is the whole of the fail-safe: a build whose `Info.plist` still carries the
/// placeholder must leave the updater unbuilt, because `SPUStandardUpdaterController`
/// answers a misconfigured bundle with an alert telling the user to contact the
/// developer — a few seconds after launch, unprompted.
@Suite("Updates")
@MainActor
struct UpdaterControllerTests {
    @Test(
        "a key is plausible only if it is 44 base64 characters of 32 bytes",
        arguments: [
            // A made-up but well-formed key: 44 base64 characters that decode to the
            // 32 bytes of an Ed25519 public key, which is what `generate_keys` prints.
            // Deliberately not the project's own key, so that this does not have to be
            // touched if the key is ever regenerated before the first release.
            ("K3l0zQ0m9YbG7t2vJhTn4pWc8sXfRdA1eBuIoLqMnCk=", true),
            // The placeholder that ships in a build made before the first release.
            ("REPLACE_WITH_SPARKLE_PUBLIC_KEY", false),
            ("", false),
            // Right alphabet, wrong length: 24 characters is a 16-byte key.
            ("K3l0zQ0m9YbG7t2vJhTn4pU=", false),
            // Right length, not base64 at all.
            (String(repeating: "!", count: 44), false),
            // 44 characters of base64 that decode to 33 bytes rather than 32.
            ("K3l0zQ0m9YbG7t2vJhTn4pWc8sXfRdA1eBuIoLqMnCkA", false),
            // A key with a space in it, as a copy-and-paste accident produces.
            ("K3l0zQ0m9YbG7t2vJhTn4pWc8sXfRdA1eBuIoLqMn k=", false),
        ]
    )
    func plausibility(key: String, expected: Bool) {
        #expect(UpdaterController.isPlausiblePublicKey(key) == expected)
    }

    @Test("a missing key is not plausible")
    func missingKey() {
        #expect(UpdaterController.isPlausiblePublicKey(nil) == false)
    }

    @Test("a bundle without a public key leaves the updater switched off")
    func unconfiguredBundle() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "de.21m.steno.tests.updates")!)
        let updater = UpdaterController(settings: settings, bundle: Bundle(for: TestBundleMarker.self))

        #expect(updater.isConfigured == false)
        #expect(updater.canCheckForUpdates == false)
        #expect(updater.lastUpdateCheckDate == nil)
        #expect(updater.unavailableReason != nil)
        // Doing nothing rather than crashing is the point: the menu item and the
        // settings button are disabled, but a stray call must be harmless.
        updater.checkForUpdates()
    }

    @Test("the shipped bundle carries a real key and a feed")
    func shippedBundle() {
        let key = Bundle.main.object(forInfoDictionaryKey: UpdaterController.publicKeyInfoKey) as? String
        #expect(UpdaterController.isPlausiblePublicKey(key))

        let feed = Bundle.main.object(forInfoDictionaryKey: UpdaterController.feedURLInfoKey) as? String
        #expect(feed?.hasSuffix("/appcast.xml") == true)
        #expect(feed.map { URL(string: $0)?.scheme == "https" } == true)
    }
}
