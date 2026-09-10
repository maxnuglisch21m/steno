import Foundation
import Sparkle

/// In-app updates: Sparkle, pointed at the appcast attached to every GitHub release.
///
/// Sparkle is wrapped rather than used directly for one reason: the app has to be able
/// to run without a working update feed. Until a release exists, `SUPublicEDKey` in
/// `Info.plist` is a placeholder, and an updater started against a placeholder key does
/// not fail quietly — `SPUStandardUpdaterController` logs the misconfiguration and, a
/// few seconds later, puts an alert in front of the user telling them to contact the
/// developer. That is the right behaviour for a shipped app whose key went missing and
/// exactly the wrong behaviour for a build made before the first release.
///
/// So the key is inspected first. A plausible key starts the updater and enables both
/// "Nach Updates suchen …" in the menu and "Jetzt suchen" in the settings; the
/// placeholder leaves the updater unbuilt, logs one line, and leaves both disabled with
/// a reason. Nothing else in the app has to know which of the two it got.
///
/// Everything here is main-actor: Sparkle's `SPUUpdater`, `SPUStandardUpdaterController`
/// and `SPUUpdaterDelegate` are all annotated `NS_SWIFT_UI_ACTOR`, so this is the
/// isolation the framework already demands rather than one imposed on top of it.
@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    /// The `Info.plist` key holding the EdDSA public key updates are verified against.
    nonisolated static let publicKeyInfoKey = "SUPublicEDKey"
    /// The `Info.plist` key holding the appcast URL.
    nonisolated static let feedURLInfoKey = "SUFeedURL"
    /// What `Info.plist` carries until a release has replaced it.
    nonisolated static let publicKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"

    private let settings: SettingsStore
    /// `nil` when the bundle has no usable public key. That is the whole switch.
    ///
    /// A `var` only because `SPUStandardUpdaterController` takes its delegate at
    /// initialization and `SPUUpdater` has no settable `delegate` afterwards, so the
    /// controller cannot be built until `self` exists.
    private var controller: SPUStandardUpdaterController?

    /// Whether the bundle is configured well enough for updates to work at all.
    var isConfigured: Bool { controller != nil }

    /// Whether a check can be started right now. `false` while one is already running,
    /// and always `false` without a feed.
    ///
    /// Read fresh rather than cached: the menu is rebuilt every time it opens, which is
    /// the only moment this is looked at.
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// When Sparkle last asked the feed, or `nil` if it never has.
    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// The feed the updater reads, for the settings window. Taken from the bundle even
    /// when the updater is not running, because it is worth showing either way.
    var feedURLString: String? {
        Bundle.main.object(forInfoDictionaryKey: Self.feedURLInfoKey) as? String
    }

    /// Why updates are unavailable, or `nil` when they are available. German, because
    /// it is shown.
    var unavailableReason: String? {
        isConfigured ? nil : String(localized: "Update-Feed noch nicht konfiguriert")
    }

    /// - Parameter bundle: the bundle whose `SUPublicEDKey` decides whether the updater
    ///   is started. Always the main bundle in the app; a test passes its own.
    init(settings: SettingsStore, bundle: Bundle = .main) {
        self.settings = settings
        let key = bundle.object(forInfoDictionaryKey: Self.publicKeyInfoKey) as? String
        let isConfigured = Self.isPlausiblePublicKey(key)
        super.init()

        guard isConfigured else { return }
        // `startingUpdater: false` so that the delegate is in place — and the
        // automatic-check setting applied — before the first scheduled check can fire.
        // `userDriverDelegate: nil`: Sparkle's standard user driver already does the
        // right thing for a menu-bar app, and there is nothing to gain from taking
        // over its dialogs.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    // MARK: - Lifecycle

    /// Starts the updater, if there is one. Called once, at launch.
    func start() {
        guard let controller else {
            Log.app.notice(
                "updates disabled: \(Self.publicKeyInfoKey, privacy: .public) is not a usable EdDSA key"
            )
            return
        }

        // Before `startUpdater()`, so the first scheduled check already honours the
        // setting rather than running once and being corrected afterwards.
        controller.updater.automaticallyChecksForUpdates = settings.settings.checkForUpdatesAutomatically
        controller.startUpdater()
        observeSettings()

        Log.app.notice(
            """
            updates enabled: feed \(self.feedURLString ?? "—", privacy: .public), \
            automatic checks \(controller.updater.automaticallyChecksForUpdates ? "on" : "off", privacy: .public)
            """
        )
    }

    /// Asks the feed now and shows Sparkle's own progress and result dialogs.
    ///
    /// The menu item and the settings button both land here. Doing nothing without a
    /// feed is deliberate: both callers are disabled in that case, and a stray call is
    /// not worth an alert.
    func checkForUpdates() {
        guard let controller else { return }
        Log.app.notice("update check requested by the user")
        controller.checkForUpdates(nil)
    }

    /// Mirrors the stored setting into Sparkle whenever it changes.
    ///
    /// `withObservationTracking` fires once per change, so it re-arms itself — the same
    /// shape `AppEnvironment` uses for the permission snapshot, and cheaper than a
    /// Combine pipeline for one boolean. Sparkle resets its own update cycle when the
    /// property is assigned, so nothing else has to happen here.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings.checkForUpdatesAutomatically
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let controller = self.controller else { return }
                let wanted = self.settings.settings.checkForUpdatesAutomatically
                if controller.updater.automaticallyChecksForUpdates != wanted {
                    controller.updater.automaticallyChecksForUpdates = wanted
                    Log.app.debug("automatic update checks \(wanted ? "on" : "off", privacy: .public)")
                }
                self.observeSettings()
            }
        }
    }

    // MARK: - SPUUpdaterDelegate

    /// The feed URL, taken from `Info.plist` unchanged.
    ///
    /// Implemented rather than omitted so that there is one obvious place to look for a
    /// feed override — and so that the answer visible there is "there is none". A
    /// channel or a beta feed would be added here; today the plist is the whole story.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: Self.feedURLInfoKey) as? String
    }

    // MARK: - Key check

    /// Whether a string looks like the EdDSA public key Sparkle expects.
    ///
    /// Sparkle keys are Ed25519 public keys: 32 raw bytes, base64-encoded, which is
    /// always 44 characters ending in a single `=`. That is enough of a shape to tell a
    /// real key from the placeholder, from an empty string, and from someone's initials
    /// pasted into the plist by accident — and it is all this check is for. Whether the
    /// key is the *right* one is not knowable here; that shows up as a failed signature
    /// check on the first update, which is exactly where it should show up.
    nonisolated static func isPlausiblePublicKey(_ key: String?) -> Bool {
        guard let key else { return false }
        guard key != publicKeyPlaceholder else { return false }
        guard key.count == 44 else { return false }
        // `Data(base64Encoded:)` is lenient about characters it does not recognise only
        // when told to be; by default a stray space or quote makes it return nil.
        guard let decoded = Data(base64Encoded: key) else { return false }
        return decoded.count == 32
    }
}
